#!/bin/bash
# Build the Balar test image and run the Balar testsuite from the workspace root.
#
#   ./quetz-docker/build-and-test-balar.sh
#   UPDATE_GOLD=1 ./quetz-docker/build-and-test-balar.sh
#
# Expects sibling directories: sst-core/, sst-elements/, quetz-docker/

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${RAPTOR_BALAR_IMAGE:-raptor-balar-test}"
# GPGPU-Sim accelwattch uses x86 SSE flags; arm64 native builds fail on Apple Silicon.
PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"

cd "${ROOT}"

echo "=== Building ${IMAGE} (platform=${PLATFORM}; CUDA 11.7 + GPGPU-Sim; first build may take 60+ minutes) ==="
docker build --platform "${PLATFORM}" -t "${IMAGE}" -f quetz-docker/Dockerfile.balar .

echo "=== Running Balar tests ==="
docker_env=(-e "UPDATE_GOLD=${UPDATE_GOLD:-0}")
if [ "$(uname -s)" = "Darwin" ]; then
    docker_env+=(-e "SKIP_QUETZ_CROSSSTACK=1")
fi
docker run --rm --platform "${PLATFORM}" \
    "${docker_env[@]}" \
    -v "${ROOT}/sst-elements:/src/sst-elements" \
    -v "${ROOT}/quetz-docker/run-balar-tests.sh:/usr/local/bin/run-balar-tests.sh:ro" \
    "${IMAGE}" \
    /usr/local/bin/run-balar-tests.sh
