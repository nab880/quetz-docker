# quetz-docker

Docker image and QEMU overlay for building and running the Quetz SST testsuite.

## Workspace layout

This repo is intended to sit alongside `sst-core/` and `sst-elements/` in a common workspace:

```
workspace/
  sst-core/        # SST core (separate git repo)
  sst-elements/    # SST elements incl. quetz (separate git repo)
  quetz-docker/    # this repo
```

## Quick start

From the workspace root:

```bash
./quetz-docker/build-and-test.sh
```

First build can take 15–30 minutes (QEMU + SST compile with `-j2`).

Manual build:

```bash
docker build -t raptor-quetz-test -f quetz-docker/Dockerfile .
docker run --rm -v "$PWD/sst-elements:/src/sst-elements" raptor-quetz-test
```

## Refresh gold files

When QEMU or statistic output changes intentionally:

```bash
UPDATE_GOLD=1 ./quetz-docker/build-and-test.sh
```

This sets `updateFiles = True` in `testsuite_default_quetz.py` for one run, then restores it.

## Image and layout

| Item | Value |
|------|--------|
| Image tag | `raptor-quetz-test` (override with `RAPTOR_QUETZ_IMAGE`) |
| SST prefix | `/opt/sst` |
| QEMU prefix | `/opt/qemu` |
| Mounted tree | `sst-elements/` → `/src/sst-elements` (live edits without rebuild) |

## QEMU overlay

`qemu-overlay/` patches QEMU 9.2.1 at Docker build time with:

- `sst-mmio-bridge` sysmode device (synchronous MMIO via Quetz shared memory)
- `quetz_ipc_client.c` — standalone IPC client for the bridge

Applied by `qemu-overlay/apply-qemu-overlay.sh` during the Docker build.

## Requirements

- Docker with enough disk (~8 GB image) and RAM (build uses `make -j2` to avoid OOM).

## Tests

Runs `sst-test-elements -p testsuite_default_quetz.py` (usermode + sysmode + PR1 checks).

### After editing Quetz C++ sources

The image ships a prebuilt `libquetz.so`. Live-mounting `sst-elements/` does **not** automatically rebuild it. Either:

1. **Full refresh** (picks up `configure.m4` / `Makefile.am` changes): `./quetz-docker/build-and-test.sh`
2. **Fast overlay** (C/C++ only, existing image) — see `rebuild-quetz-usermode-gpu.sh`

Build firmware once per mount: `RV64_CC=riscv64-linux-gnu-gcc ./tests/sysmode/firmware/build.sh` (inside the container).
