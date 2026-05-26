#!/bin/bash
# Run Balar SST tests inside the raptor-balar-test container.
#
# Host usage (workspace root):
#   ./quetz-docker/build-and-test-balar.sh
#   UPDATE_GOLD=1 ./quetz-docker/build-and-test-balar.sh

set -eo pipefail

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
# GPGPU-Sim setup_environment references these; unset vars trip `set -u`.
export OPENCL_REMOTE_GPU_HOST="${OPENCL_REMOTE_GPU_HOST:-}"
export OPENCL_REMOTE_GPU_PORT="${OPENCL_REMOTE_GPU_PORT:-}"

# shellcheck source=/dev/null
source "${GPGPUSIM_ROOT}/setup_environment" sst

BALAR_TESTS="/src/sst-elements/src/sst/elements/balar/tests"
TESTSUITE="${BALAR_TESTS}/testsuite_default_balar.py"

echo "=== CUDA / GPGPU-Sim ==="
nvcc --version | head -1 || true
echo "GPGPUSIM_ROOT=${GPGPUSIM_ROOT}"
echo "GPU_ARCH=${GPU_ARCH}"

echo "=== Element registration (balar + quetz when present) ==="
sst-info balar 2>/dev/null | head -20 || true
if [ -d /src/sst-elements/src/sst/elements/quetz ]; then
    sst-info quetz 2>/dev/null | head -20 || true
fi

# Rebuild balar from the mounted sst-elements tree when present (dev iteration).
if [ -d /build/sst-elements/src/sst/elements/balar ] && [ -d /src/sst-elements/src/sst/elements/balar ]; then
    echo "=== Rebuilding balar from mounted sources ==="
    cp /src/sst-elements/src/sst/elements/balar/testcpu/quetzTestCPU.* \
       /build/sst-elements/src/sst/elements/balar/testcpu/ 2>/dev/null || true
    (cd /build/sst-elements/src/sst/elements/balar && make -j"$(nproc)" install) || true
fi

echo "=== Balar testsuite (smoke + integration) ==="
"${SST_PREFIX}/bin/sst-test-elements" -p "${TESTSUITE}"

# Combined-tree validation: run Quetz suite on the balar image when the element is mounted.
if [ -d /src/sst-elements/src/sst/elements/quetz ] && [ -x /usr/local/bin/run-quetz-tests.sh ]; then
    echo "=== Quetz testsuite on balar image (combined tree) ==="
    /usr/local/bin/run-quetz-tests.sh
fi

echo "=== All Balar tests passed ==="
