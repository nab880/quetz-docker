#!/bin/bash
# Build the Quetz test image and run the full testsuite from the workspace root.
#
#   ./quetz-docker/build-and-test.sh
#   UPDATE_GOLD=1 ./quetz-docker/build-and-test.sh
#
# Expects sibling directories: sst-core/, sst-elements/, quetz-docker/

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${RAPTOR_QUETZ_IMAGE:-raptor-quetz-test}"

cd "${ROOT}"

echo "=== Building ${IMAGE} (this may take several minutes) ==="
docker build -t "${IMAGE}" -f quetz-docker/Dockerfile .

echo "=== Running Quetz tests ==="
docker run --rm \
    -e "UPDATE_GOLD=${UPDATE_GOLD:-0}" \
    -v "${ROOT}/sst-elements:/src/sst-elements" \
    "${IMAGE}" \
    /usr/local/bin/run-quetz-tests.sh
