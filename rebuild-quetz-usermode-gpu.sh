#!/bin/bash
# Rebuild quetz (with QuetzGpuDevice) inside raptor-quetz-test and run usermode GPU tests.
# Usage from workspace root: ./quetz-docker/rebuild-quetz-usermode-gpu.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${RAPTOR_QUETZ_IMAGE:-raptor-quetz-test}"
QUETZ_MOUNT="${ROOT}/sst-elements/src/sst/elements/quetz"

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Image ${IMAGE} not found; run: docker build --target build -t ${IMAGE} -f quetz-docker/Dockerfile ."
    exit 1
fi

BIN_OUT="${QUETZ_MOUNT}/tests/binaries"
mkdir -p "${BIN_OUT}"

docker run --rm \
    -v "${QUETZ_MOUNT}:/quetz-mount:ro" \
    -v "${BIN_OUT}:/host-binaries" \
    "${IMAGE}" \
    bash -c "$(cat <<'INNER'
set -euo pipefail
export PATH=/opt/sst/bin:/opt/qemu/bin:$PATH
export LD_LIBRARY_PATH=/opt/sst/lib
export SST_HOME=/opt/sst
B=/build/sst-elements/src/sst/elements/quetz
MK="$B/Makefile"
BINDIR=/tmp/quetz-binaries
mkdir -p "$BINDIR"

echo "=== Sync quetz sources into build tree ==="
cp /quetz-mount/*.cc /quetz-mount/*.h "$B/"
cp -r /quetz-mount/qemu_plugin "$B/"

python3 << "PY"
from pathlib import Path
mk = Path("/build/sst-elements/src/sst/elements/quetz/Makefile")
text = mk.read_text()
src_needle = "    quetz_region_handlers.h \\\n"
src_insert = src_needle + "    quetz_gpu_device.cc \\\n    quetz_gpu_device.h \\\n"
obj_needle = "\tlibquetz_la-quetz_region_handlers.lo \\\n"
obj_insert = obj_needle + "\tlibquetz_la-quetz_gpu_device.lo \\\n"
if "quetz_gpu_device.cc" not in text:
    if src_needle not in text or obj_needle not in text:
        raise SystemExit("Makefile patch point not found")
    text = text.replace(src_needle, src_insert, 1)
    text = text.replace(obj_needle, obj_insert, 1)
    rule_anchor = "libquetz_la-quetz_region_handlers.lo: quetz_region_handlers.cc"
    if rule_anchor not in text:
        raise SystemExit("Makefile compile-rule anchor not found")
    block_start = text.index(rule_anchor)
    block_end = text.index("libquetz_la-quetz_mem_access.lo:", block_start)
    block = text[block_start:block_end]
    gpu_block = block.replace("region_handlers", "gpu_device")
    text = text[:block_end] + gpu_block + text[block_end:]
    mk.write_text(text)
    print("Patched Makefile SOURCES + OBJECTS + compile rule for quetz_gpu_device")
else:
    print("Makefile already lists quetz_gpu_device")
PY

echo "=== Rebuild libquetz + plugin (do not rerun config.status — it drops the patch) ==="
make -C /build/sst-elements/src/sst/elements/quetz clean
make -j$(nproc) -C /build/sst-elements/src/sst/elements/quetz install
if ! ls "$B"/libquetz_la-quetz_gpu_device.lo >/dev/null 2>&1; then
    echo "ERROR: libquetz_la-quetz_gpu_device.lo was not built" >&2
    exit 1
fi

if ! /opt/sst/bin/sst-info quetz 2>&1 | grep -q QuetzGpuDevice; then
    echo "ERROR: QuetzGpuDevice not registered after rebuild" >&2
    /opt/sst/bin/sst-info quetz 2>&1 | head -40
    exit 1
fi
echo "QuetzGpuDevice registered."

echo "=== Build usermode GPU guest binaries ==="
CC=riscv64-linux-gnu-gcc
$CC -static -O2 /quetz-mount/tests/usermode/sources/gpu_kernel_user.c -o "$BINDIR/gpu_kernel_user"
$CC -static -O2 /quetz-mount/tests/usermode/sources/gpu_trace_user.c -o "$BINDIR/gpu_trace_user"

echo "=== test_quetz_usermode_gpu_kernel (via sst) ==="
export QUETZ_EXE=$BINDIR/gpu_kernel_user
export QUETZ_QEMU=/opt/sst/bin/qemu-riscv64
export QUETZ_PLUGIN=/opt/sst/libexec/libqemu_sst_plugin.so
export QUETZ_MMIO_START=0x80100000 QUETZ_MMIO_END=0x801003FF
export QUETZ_REGION_HANDLER_COUNT=3
export QUETZ_REGION_HANDLER0_START=0x80000000 QUETZ_REGION_HANDLER0_END=0x800FFFFF QUETZ_REGION_HANDLER0_TYPE=filtered
export QUETZ_REGION_HANDLER1_START=0 QUETZ_REGION_HANDLER1_END=0x7FFFFFFF QUETZ_REGION_HANDLER1_TYPE=filtered
export QUETZ_REGION_HANDLER2_START=0x80100400 QUETZ_REGION_HANDLER2_END=$(( (1 << 48) - 1 )) QUETZ_REGION_HANDLER2_TYPE=filtered

KOUT=/tmp/usermode_gpu_kernel.out
export QUETZ_GPU_LATENCY=100
timeout 90 sst /quetz-mount/tests/usermode/basic_quetz_gpu.py > "$KOUT" 2>&1 || true
python3 << "PY"
import re, sys
text = open("/tmp/usermode_gpu_kernel.out").read()
if "FATAL" in text or "MPI_ABORT" in text:
    print(text[-4000:])
    sys.exit(1)
if "Simulation is complete" not in text:
    print("Simulation did not complete; tail:")
    print(text[-4000:])
    sys.exit(1)
def stat(name):
    m = re.search(rf" {re.escape(name)} : Accumulator : Sum.u64 = (\d+)", text)
    return int(m.group(1)) if m else None
mmio_w = stat("cpu.mmio_write_requests.0")
mmio_r = stat("cpu.mmio_read_requests.0")
wr = stat("cpu.write_requests.0")
kl = re.search(r" gpu.kernels_launched : Accumulator : Sum.u64 = (\d+)", text)
bc = re.search(r" gpu.busy_cycles : Accumulator : Sum.u64 = (\d+)", text)
kernels = int(kl.group(1)) if kl else None
busy = int(bc.group(1)) if bc else None
print(f"mmio_write={mmio_w} mmio_read={mmio_r} write_requests={wr} kernels={kernels} busy={busy}")
assert mmio_w is not None and mmio_w >= 6, mmio_w
assert mmio_r is not None and mmio_r >= 3, mmio_r
assert wr == 0, wr
assert kernels == 3, kernels
assert busy is not None and busy > 0, busy
print("kernel test OK")
PY

echo "=== test_quetz_usermode_gpu_trace_capture (via sst) ==="
export QUETZ_EXE=$BINDIR/gpu_trace_user
unset QUETZ_REGION_HANDLER_COUNT
unset QUETZ_REGION_HANDLER0_START QUETZ_REGION_HANDLER0_END QUETZ_REGION_HANDLER0_TYPE
unset QUETZ_REGION_HANDLER1_START QUETZ_REGION_HANDLER1_END QUETZ_REGION_HANDLER1_TYPE
unset QUETZ_REGION_HANDLER2_START QUETZ_REGION_HANDLER2_END QUETZ_REGION_HANDLER2_TYPE
export QUETZ_REGION_HANDLER_COUNT=1
export QUETZ_REGION_HANDLER0_START=0x80100400 QUETZ_REGION_HANDLER0_END=$(( (1 << 48) - 1 )) QUETZ_REGION_HANDLER0_TYPE=filtered
TOUT=/tmp/usermode_gpu_trace.out
timeout 60 sst /quetz-mount/tests/usermode/basic_quetz_gpu_trace.py > "$TOUT" 2>&1 || true
python3 << "PY"
import sys
text = open("/tmp/usermode_gpu_trace.out").read()
if "FATAL" in text:
    print(text[-3000:])
    sys.exit("sim failed")
assert "cpu.gpu_doorbell_writes.0" in text and "Sum.u64 = 1" in text.split("gpu_doorbell_writes.0")[1][:120]
assert "cpu.gpu_status_polls.0" in text and "Sum.u64 = 8" in text.split("gpu_status_polls.0")[1][:120]
assert "GPU_TRACE[0]:" in text
line = text[text.find("GPU_TRACE[0]:"):text.find("\n", text.find("GPU_TRACE[0]:"))]
assert "doorbells=1" in line and "polls=8" in line and "deadbeef" in line.lower()
print("trace test OK")
PY

cp "$BINDIR/gpu_kernel_user" "$BINDIR/gpu_trace_user" /host-binaries/
ls -la /host-binaries/gpu_*

echo "=== All usermode GPU checks passed ==="
INNER
)"

echo "Done."
