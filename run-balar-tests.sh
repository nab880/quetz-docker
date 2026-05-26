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

rebuild_quetz_from_mount() {
    local src="/src/sst-elements/src/sst/elements/quetz"
    local bld="/build/sst-elements/src/sst/elements/quetz"
    if [ ! -d "${src}" ] || [ ! -d /build/sst-elements/src/sst/elements ]; then
        return 0
    fi
    echo "=== Rebuilding quetz from mounted sources ==="
    mkdir -p "${bld}"
    cp -a "${src}/." "${bld}/"
    if [ -f "${bld}/Makefile" ]; then
        make -j"$(nproc)" -C "${bld}" install || return 1
        "${SST_PREFIX}/bin/sst-register" SST_ELEMENT_SOURCE quetz="${src}" || true
        "${SST_PREFIX}/bin/sst-register" SST_ELEMENT_TESTS quetz="${src}/tests" || true
    fi
}

if [ -d /src/sst-elements/src/sst/elements/quetz ]; then
    rebuild_quetz_from_mount || echo "WARN: quetz rebuild skipped or failed"
    sst-info quetz 2>/dev/null | head -20 || true
fi

# Rebuild balar from the mounted sst-elements tree when present (dev iteration).
if [ -d /build/sst-elements/src/sst/elements/balar ] && [ -d /src/sst-elements/src/sst/elements/balar ]; then
    echo "=== Rebuilding balar from mounted sources ==="
    cp /src/sst-elements/src/sst/elements/balar/testcpu/quetzTestCPU.* \
       /build/sst-elements/src/sst/elements/balar/testcpu/ 2>/dev/null || true
    (cd /build/sst-elements/src/sst/elements/balar && make -j"$(nproc)" install) || true
fi

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

# Combined-tree validation: run Quetz suite on the balar image when the element is mounted.
if [ -d /src/sst-elements/src/sst/elements/quetz ] && [ -x /usr/local/bin/run-quetz-tests.sh ]; then
    if sst-info quetz 2>/dev/null | grep -q QuetzComponent; then
        echo "=== Quetz testsuite on balar image (combined tree) ==="
        if ! /usr/local/bin/run-quetz-tests.sh; then
            QUETZ_RC=1
        fi
    else
        echo "NOTE: quetz sources mounted but element not registered — skip cross-stack Quetz suite"
        echo "      Rebuild raptor-balar-test with quetz present (quetz-gpu-balar-combined tree)"
    fi
fi

if [ "${BALAR_RC}" -ne 0 ] || [ "${QUETZ_RC}" -ne 0 ]; then
    echo "=== Balar/Quetz validation FAILED (balar=${BALAR_RC} quetz=${QUETZ_RC}) ==="
    exit 1
fi

echo "=== All Balar tests passed ==="
