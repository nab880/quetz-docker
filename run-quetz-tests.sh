#!/bin/bash
# Run Quetz SST tests inside the raptor-quetz-test container.
#
# Host usage (from workspace root):
#   ./quetz-docker/build-and-test.sh
#   UPDATE_GOLD=1 ./quetz-docker/build-and-test.sh   # refresh gold files in the tree

set -euo pipefail

SST_PREFIX="${SST_PREFIX:-/opt/sst}"
export PATH="${SST_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${SST_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export SST_HOME="${SST_PREFIX}"
export QEMU_PLUGIN_DIR="${QEMU_PLUGIN_DIR:-/opt/qemu/lib/qemu/plugins}"

QUETZ_DIR="/src/sst-elements/src/sst/elements/quetz"
TESTSUITE="${QUETZ_DIR}/tests/testsuite_default_quetz.py"

echo "=== QEMU versions ==="
qemu-system-x86_64 --version 2>/dev/null | head -1 || true
qemu-riscv64 --version 2>/dev/null | head -1 || true

echo "=== Quetz install ==="
ls -la "${SST_PREFIX}/lib/sst-elements-library/"libquetz* 2>/dev/null || true
ls -la "${SST_PREFIX}/libexec/"libqemu_sst_plugin* 2>/dev/null || true
ls -la "${QEMU_PLUGIN_DIR}/libmem.so" 2>/dev/null || true

if [ "${UPDATE_GOLD:-0}" = "1" ]; then
    echo "=== Regenerating gold files (UPDATE_GOLD=1) ==="
    sed -i 's/^updateFiles = False/updateFiles = True/' "${TESTSUITE}"
    trap 'sed -i "s/^updateFiles = True/updateFiles = False/" "${TESTSUITE}"' EXIT
fi

echo "=== Quetz unit tests ==="
"${QUETZ_DIR}/tests/unit/run_unit_tests.sh"

echo "=== Building sysmode RISC-V firmware ==="
if command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then
    FW_DIR="${QUETZ_DIR}/tests/sysmode/firmware"
    export RV64_CC="${RV64_CC:-riscv64-linux-gnu-gcc}"
    RV64_FLAGS="-march=rv64gc -mabi=lp64d -O2 -mcmodel=medany \
      -nostdlib -nostartfiles -ffreestanding -mno-relax \
      -T link_rv64.ld -Wl,--build-id=none"
    (
        cd "${FW_DIR}"
        for fw in riscv_virt_hello riscv_virt_uart_echo riscv_virt_mmio_poke \
                  riscv_virt_gpu_trace riscv_virt_gpu_kernel \
                  riscv_virt_gpu_fft riscv_virt_gpu_fft_offload \
                  riscv_virt_balar_kernel; do
            if [ -f "${fw}.c" ]; then
                echo "  building ${fw}..."
                ${RV64_CC} ${RV64_FLAGS} "${fw}.c" -o "${fw}" || \
                    echo "WARN: ${fw} build failed"
            fi
        done
    )
else
    echo "NOTE: riscv64-linux-gnu-gcc not found — skipping sysmode firmware build"
fi

echo "=== Building sysmode ColdFire (m68k) firmware ==="
if command -v m68k-linux-gnu-gcc >/dev/null 2>&1; then
    FW_DIR="${QUETZ_DIR}/tests/sysmode/firmware"
    export M68K_CC="${M68K_CC:-m68k-linux-gnu-gcc}"
    # NXP ColdFire MCF5208 (big-endian m68k), QEMU mcf5208evb. Matches build.sh.
    M68K_FLAGS="-mcpu=5208 -O2 -nostdlib -nostartfiles -ffreestanding \
      -T link_m68k.ld -Wl,--build-id=none"
    (
        cd "${FW_DIR}"
        # Device-computed FFT (kernel_type=fft): no float/fixed-point math on the
        # guest (raw u32 bit-pattern compares), so plain M68K_FLAGS.
        echo "  building coldfire_gpu_fft_offload..."
        ${M68K_CC} ${M68K_FLAGS} coldfire_startup.S coldfire_gpu_fft_offload.c \
            -o coldfire_gpu_fft_offload || echo "WARN: coldfire_gpu_fft_offload build failed"
        # CPU-compute contrast (Q16.16 fixed point; firmware ships its own __muldi3,
        # so no -lgcc — the m68k libgcc soft-float helpers hang on ColdFire V2).
        echo "  building coldfire_gpu_fft..."
        ${M68K_CC} ${M68K_FLAGS} -DFFT_FIXED_POINT coldfire_startup.S coldfire_gpu_fft.c \
            -o coldfire_gpu_fft || echo "WARN: coldfire_gpu_fft build failed"
        echo "  building expanded ColdFire regression firmware..."
        (cd expanded && ./build.sh)
    )
else
    echo "NOTE: m68k-linux-gnu-gcc not found — skipping ColdFire firmware build"
fi

echo "=== Building microbenchmark ELFs (optional) ==="
if command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then
    (cd "${QUETZ_DIR}/tests/binaries" && ./build_microbench.sh) || \
        echo "WARN: microbenchmark build failed — stride_scaling may skip"
else
    echo "NOTE: riscv64-linux-gnu-gcc not found — skipping microbench build"
fi

echo "=== Building usermode GPU test ELFs ==="
if command -v riscv64-linux-gnu-gcc >/dev/null 2>&1 || \
   command -v riscv64-unknown-linux-gnu-gcc >/dev/null 2>&1; then
    (cd "${QUETZ_DIR}/tests/usermode/sources" && ./build.sh) || \
        echo "WARN: usermode GPU binary build failed — usermode_gpu_* tests may skip"
else
    echo "NOTE: RISC-V Linux cross compiler not found — skipping usermode GPU build"
fi

echo "=== Quetz integration tests ==="
cd "${QUETZ_DIR}/tests"
"${SST_PREFIX}/bin/sst-test-elements" -p "${TESTSUITE}"

echo "=== Quetz expanded ColdFire regression tests ==="
"${SST_PREFIX}/bin/sst-test-elements" \
    -p "${QUETZ_DIR}/tests/expanded_coldfire_tests.py"

if [ "${UPDATE_GOLD:-0}" = "1" ]; then
    echo "Gold files updated under src/sst/elements/quetz/tests/"
fi

echo "=== Quetz libmem ground-truth validation ==="
if python3 "${QUETZ_DIR}/tests/manual/validate_against_libmem.py"; then
    :
else
    echo "WARN: libmem validation failed (non-fatal until baselined)"
fi

echo "=== quetz-run smoke (packaging contract) ==="
if command -v quetz-run >/dev/null; then
    SMOKE_OUT=/tmp/quetz-run-smoke
    rm -rf "${SMOKE_OUT}"
    if quetz-run --no-docker --quiet --out "${SMOKE_OUT}"; then
        for f in transcript.txt stats.csv sst.log result.txt; do
            [ -s "${SMOKE_OUT}/${f}" ] || { echo "FAIL: quetz-run artifact ${f} missing/empty"; exit 1; }
        done
        grep -q "SYSTEM DEMO PASS" "${SMOKE_OUT}/transcript.txt" \
            || { echo "FAIL: demo transcript missing PASS line"; exit 1; }
        echo "quetz-run smoke OK (exit 0, artifacts complete)"
    else
        echo "FAIL: quetz-run demo did not exit 0"; exit 1
    fi
else
    echo "quetz-run not on PATH; skipping smoke"
fi

echo "=== All Quetz tests passed ==="
