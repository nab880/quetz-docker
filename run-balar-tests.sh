#!/bin/bash
# Run Balar SST tests inside the raptor-balar-test container.
#
# Host usage (workspace root):
#   ./quetz-docker/build-and-test-balar.sh
#   UPDATE_GOLD=1 ./quetz-docker/build-and-test-balar.sh

set -uo pipefail

SST_PREFIX="${SST_PREFIX:-/opt/sst}"
GPGPUSIM_ROOT="${GPGPUSIM_ROOT:-/opt/gpgpu-sim}"
export PATH="${SST_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${SST_PREFIX}/lib:${CUDA_HOME:-/usr/local/cuda}/lib64:${LD_LIBRARY_PATH:-}"
export SST_HOME="${SST_PREFIX}"
export CUDA_INSTALL_PATH="${CUDA_INSTALL_PATH:-/usr/local/cuda}"
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export GPU_ARCH="${GPU_ARCH:-sm_70}"
export GPGPUSIM_ROOT="${GPGPUSIM_ROOT:-/opt/gpgpu-sim}"
export CUDA_INSTALL_PATH="${CUDA_INSTALL_PATH:-/usr/local/cuda}"
export OPENCL_REMOTE_GPU_HOST="${OPENCL_REMOTE_GPU_HOST:-}"
export OPENCL_REMOTE_GPU_PORT="${OPENCL_REMOTE_GPU_PORT:-}"
export PTXAS_CUDA_INSTALL_PATH="${PTXAS_CUDA_INSTALL_PATH:-${CUDA_INSTALL_PATH:-/usr/local/cuda}}"

# shellcheck source=/dev/null
set +u
source "${GPGPUSIM_ROOT}/setup_environment" sst
set -u

BALAR_TESTS="/src/sst-elements/src/sst/elements/balar/tests"
TESTSUITE="${BALAR_TESTS}/testsuite_default_balar.py"
BALAR_RC=0
QUETZ_RC=0

echo "=== CUDA / GPGPU-Sim ==="
nvcc --version | head -1 || true
echo "GPGPUSIM_ROOT=${GPGPUSIM_ROOT}"
echo "GPU_ARCH=${GPU_ARCH}"

echo "=== Element registration (balar + quetz when present) ==="
sst-info balar 2>/dev/null | head -20 || true

echo "=== Element registration (balar + quetz when present) ==="
sst-info balar 2>/dev/null | head -20 || true
sst-info quetz 2>/dev/null | head -20 || true

# Quetz must be built into the image (Dockerfile.balar on quetz-gpu-balar-combined tree).
# Do not rebuild from the mounted tree: copied Makefiles may embed host compiler paths.
rebuild_balar_from_mount() {
    local src="/src/sst-elements/src/sst/elements/balar"
    local bld="/build/sst-elements/src/sst/elements/balar"
    if [ ! -d "${src}" ] || [ ! -d "${bld}" ]; then
        return 0
    fi
    echo "=== Rebuilding balar from mounted sources ==="
    cp -a "${src}/testcpu/." "${bld}/testcpu/"
    make -j"$(nproc)" -C "${bld}" install
}

build_balar_vectoradd() {
    local trace_dir="/src/sst-elements/src/sst/elements/balar/tests/balar_trace"
    if [ ! -d "${trace_dir}" ]; then
        return 0
    fi
    if [ -x "${trace_dir}/vectorAdd" ]; then
        return 0
    fi
    echo "=== Building balar_trace vectorAdd (GPGPU-Sim CUDA binary) ==="
    if ! make -C "${trace_dir}" vectorAdd; then
        echo "WARN: vectorAdd build failed — sysmode_balar tests may skip"
    fi
}

rebuild_balar_from_mount
build_balar_vectoradd

if [ "${UPDATE_GOLD:-0}" = "1" ]; then
    echo "=== UPDATE_GOLD=1: refresh vectorAdd stat gold after tests ==="
fi

echo "=== Balar testsuite (smoke + integration) ==="
if ! "${SST_PREFIX}/bin/sst-test-elements" -p "${TESTSUITE}"; then
    BALAR_RC=1
fi

VECADD_STATS="${BALAR_TESTS}/sst_test_outputs/run_data/test_gpgpu_vectorAdd.stats_out"
VECADD_GOLD="${BALAR_TESTS}/refFiles/test_gpgpu_vectorAdd.out"
if [ "${UPDATE_GOLD:-0}" = "1" ] && [ -f "${VECADD_STATS}" ]; then
    cp "${VECADD_STATS}" "${VECADD_GOLD}"
    echo "Updated gold: ${VECADD_GOLD}"
fi

# Combined-tree validation: run Quetz suite on the balar image when the element is built.
# Item #2 requires native linux/amd64 (GPGPU-Sim image is amd64-only). On macOS hosts,
# Docker runs that image under Rosetta and Quetz usermode tests fail mmap ("rosetta error").
# Cross-stack guard diagnostics: a silently-skipped cross-stack is a false green
# (the doorbell/sysmode_balar tests never run). Log exactly what we see.
QUETZ_SRC_DIR="/src/sst-elements/src/sst/elements/quetz"
QUETZ_RUNNER="/usr/local/bin/run-quetz-tests.sh"
echo "=== Cross-stack guard ==="
echo "  SKIP_QUETZ_CROSSSTACK=${SKIP_QUETZ_CROSSSTACK:-0}"
echo "  quetz sources dir: $( [ -d "${QUETZ_SRC_DIR}" ] && echo present || echo MISSING ) (${QUETZ_SRC_DIR})"
ls -l "${QUETZ_RUNNER}" 2>&1 || echo "  run-quetz-tests.sh: MISSING (${QUETZ_RUNNER})"

if [ "${SKIP_QUETZ_CROSSSTACK:-0}" = "1" ]; then
    echo "NOTE: SKIP_QUETZ_CROSSSTACK=1 — skip Quetz-on-balar-image (item #2); use native linux/amd64 CI"
elif [ -d "${QUETZ_SRC_DIR}" ]; then
    # Invoke via `bash` rather than requiring the executable bit: actions/checkout
    # and bind mounts do not always preserve +x, which previously caused the whole
    # cross-stack suite to be silently skipped while CI still went green.
    # Capture sst-info to a var first; piping into `grep -q` can trip pipefail
    # via SIGPIPE on sst-info when grep closes the pipe early.
    QUETZ_INFO="$(sst-info quetz 2>/dev/null || true)"
    if [ ! -f "${QUETZ_RUNNER}" ]; then
        echo "ERROR: quetz sources present but ${QUETZ_RUNNER} is missing — cannot run cross-stack"
        QUETZ_RC=1
    elif printf '%s' "${QUETZ_INFO}" | grep -q QuetzComponent; then
        echo "=== Quetz testsuite on balar image (combined tree) ==="
        # Prebuilt aarch64/x86_64 hello binaries have glibc-sensitive stats; the
        # gold files come from the lightweight (Ubuntu 24.04) image. Skip them
        # on this Ubuntu 22.04 amd64 image — item #1 covers them.
        # Also skip stat gold on cross-stack: Round 2 IPC/stats drift vs the
        # lightweight gold baseline; behavioral checks (incl. sysmode_balar) still run.
        if ! QUETZ_SKIP_PREBUILT_USERMODE=1 QUETZ_SKIP_GOLD=1 bash "${QUETZ_RUNNER}"; then
            QUETZ_RC=1
        fi
    else
        echo "ERROR: quetz sources present but element not registered — cross-stack cannot run"
        echo "       Rebuild raptor-balar-test with quetz present (quetz-gpu-balar-combined tree)"
        QUETZ_RC=1
    fi
else
    echo "NOTE: quetz sources not present — skipping cross-stack Quetz suite"
fi

if [ "${BALAR_RC}" -ne 0 ] || [ "${QUETZ_RC}" -ne 0 ]; then
    echo "=== Balar/Quetz validation FAILED (balar=${BALAR_RC} quetz=${QUETZ_RC}) ==="
    exit 1
fi

echo "=== All Balar tests passed ==="
