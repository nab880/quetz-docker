# quetz-docker

Docker build and test environment for the [Quetz](https://github.com/sstsimulator/sst-elements/tree/master/src/sst/elements/quetz) SST element. This repo produces a self-contained image with:

- **QEMU 9.2.1** (user-mode + system-mode, with plugin API)
- **QEMU MMIO overlay** — `sst-mmio-bridge` device for synchronous guest MMIO via Quetz shared memory
- **SST-Core** and **SST-Elements** (`memHierarchy`, `mmu`, `quetz`)
- **`libqemu_sst_plugin.so`** — Quetz's QEMU plugin

Use it to build and run the Quetz regression suite without installing SST or QEMU on your host.

**Balar + GPGPU-Sim** tests use a separate CUDA-based image — see [README-balar.md](README-balar.md) and `./quetz-docker/build-and-test-balar.sh`.

| Script | Image | Purpose |
|--------|-------|-------|
| `./quetz-docker/build-and-test.sh` | `raptor-quetz-test` (`Dockerfile`, `--target build`) | Quetz testsuite (no CUDA) |
| `./quetz-docker/build-and-test-balar.sh` | `raptor-balar-test` (`Dockerfile.balar`) | Balar / GPGPU-Sim + QuetzTestCPU contract tests |
| `./quetz-docker/quetz-run` | `quetz-sim` (`Dockerfile`, `--target runtime`) | **Run your own simulation** — see below |

## Running your own simulation (`quetz-run`)

The `runtime` image target is the user-facing product: the sim + patched QEMU
+ m68k/riscv cross compilers, no build system. `quetz-run` wraps it with an
artifacts + exit-code contract (0 = guest PASS sentinel, 2 = FAIL,
1 = error/timeout):

```bash
docker build --target runtime -t quetz-sim -f quetz-docker/Dockerfile .
./quetz-docker/quetz-run --out artifacts/          # shipped ColdFire demo
./quetz-docker/quetz-run --firmware my_app.elf --stdin my_gps.nmea \
                         --sensor my_stream.bin --out artifacts/
```

Artifacts: `transcript.txt` (guest serial), `stats.csv`, `sst.log`,
`result.txt`. Own deck: start from
`sst-elements/src/sst/elements/quetz/tests/sysmode/template_system.py`.
Fixture tooling lives in `sst-elements/.../quetz/tools/`. Full walkthrough:
`SIMULATING-YOUR-SYSTEM.md` in the element. **Images bake the element at
build time — rebuild `quetz-sim` after changing element code** (the test
image instead rebuilds from the `/src` mount at test time).

---

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| **Docker** | Desktop or Engine; ~8 GB free disk for the image |
| **RAM** | Build uses `make -j2` to reduce OOM risk; 8 GB+ recommended |
| **Git** | To clone the sibling repos below |

No host install of SST, QEMU, or cross-compilers is required — everything is inside the image.

---

## Workspace setup

`quetz-docker` does **not** contain Quetz source code. Clone three repos into a common parent directory:

```bash
mkdir -p ~/dev/quetz-workspace && cd ~/dev/quetz-workspace

git clone https://github.com/sstsimulator/sst-core.git
git clone https://github.com/sstsimulator/sst-elements.git   # or your fork/branch
git clone https://github.com/YOUR_ORG/quetz-docker.git
```

Expected layout:

```
quetz-workspace/
├── sst-core/          # SST core
├── sst-elements/      # SST elements (Quetz lives under src/sst/elements/quetz/)
└── quetz-docker/      # this repo
```

All commands below assume your shell is at **`quetz-workspace/`** (the parent of all three directories).

> **Tip:** If you keep a local checkout named `raptor/` with the same three siblings, that works too — only the relative paths matter.

---

## Quick start

From the workspace root:

```bash
./quetz-docker/build-and-test.sh
```

This will:

1. Build the Docker image `raptor-quetz-test` (~15–30 minutes on first run)
2. Run the full Quetz testsuite inside a container
3. Mount your host `sst-elements/` tree so Python tests and guest binaries are read live

Success looks like:

```text
== TESTING PASSED ==
=== All Quetz tests passed ===
```

---

## Manual build and run

### Build the image only

```bash
docker build -t raptor-quetz-test -f quetz-docker/Dockerfile .
```

Override the image name:

```bash
export RAPTOR_QUETZ_IMAGE=my-quetz-test
docker build -t "${RAPTOR_QUETZ_IMAGE}" -f quetz-docker/Dockerfile .
```

### Run tests only (image already built)

```bash
docker run --rm \
  -v "$(pwd)/sst-elements:/src/sst-elements" \
  raptor-quetz-test \
  /usr/local/bin/run-quetz-tests.sh
```

The volume mount means changes under `sst-elements/src/sst/elements/quetz/tests/` (Python, SDL, gold files, firmware sources) are picked up immediately. **C/C++ library changes** still require an image rebuild (see below).

---

## What runs inside the container

`/usr/local/bin/run-quetz-tests.sh` (copied from this repo at build time) does the following:

1. Print QEMU and Quetz install paths
2. Run Quetz **unit tests** (`tests/unit/run_unit_tests.sh`)
3. Cross-compile **sysmode RISC-V firmware** (`tests/sysmode/firmware/*.c`)
4. Build optional **microbenchmark** and **usermode GPU** ELFs
5. Run **integration tests** via `sst-test-elements -p testsuite_default_quetz.py`
6. Optionally run **libmem ground-truth validation** (skipped if `libmem.so` is absent)

---

## Rebuild after code changes

| What changed | Action |
|--------------|--------|
| Python tests, SDL, gold files | Re-run tests only (no rebuild) |
| Quetz C++ / plugin / `Makefile.am` / `configure.m4` | Full rebuild: `./quetz-docker/build-and-test.sh` |
| QEMU overlay (`qemu-overlay/`) or `Dockerfile` | Full rebuild (QEMU layer is baked in) |
| Fast iteration on Quetz C++ only | `./quetz-docker/rebuild-quetz-usermode-gpu.sh` (rebuilds `libquetz` inside existing image) |

### Full rebuild

```bash
./quetz-docker/build-and-test.sh
```

### Fast C++ overlay (usermode GPU path)

After the image exists, this script rebuilds Quetz inside the container and runs the usermode GPU tests:

```bash
./quetz-docker/rebuild-quetz-usermode-gpu.sh
```

---

## Refresh gold files

Usermode tests compare SST stdout against `*.gold` reference files. When statistic output changes intentionally (new QEMU version, plugin change, etc.):

```bash
UPDATE_GOLD=1 ./quetz-docker/build-and-test.sh
```

Or, if the image is already built:

```bash
UPDATE_GOLD=1 docker run --rm \
  -v "$(pwd)/sst-elements:/src/sst-elements" \
  raptor-quetz-test \
  /usr/local/bin/run-quetz-tests.sh
```

This temporarily sets `updateFiles = True` in `testsuite_default_quetz.py`, writes new gold files into your mounted `sst-elements` tree, then restores the flag.

**Do not** refresh gold to mask hangs or plugin load failures — only use when the new numbers are correct.

---

## Image layout

| Path | Contents |
|------|----------|
| `/opt/sst` | SST install prefix (`sst`, `sst-test-elements`, `libquetz.so`) |
| `/opt/sst/libexec/` | `libqemu_sst_plugin.so` |
| `/opt/qemu` | Patched QEMU 9.2.1 binaries |
| `/opt/qemu/lib/qemu/plugins/` | QEMU contrib plugins (incl. `libmem.so` when built) |
| `/src/sst-elements` | Mounted from host at run time |

Environment variables set in the container:

- `SST_HOME=/opt/sst`
- `QEMU_PLUGIN_DIR=/opt/qemu/lib/qemu/plugins`

---

## QEMU overlay (pinned)

**Base: upstream QEMU 9.2.1** (fetched from download.qemu.org in the
Dockerfile; `ARG QEMU_VERSION` pins it). The `qemu-overlay/` directory is
applied by `apply-qemu-overlay.sh` — it fails loudly if any piece does not
apply, so a QEMU version bump cannot silently drop the overlay.

Copied sources:

| Component | Purpose |
|-----------|---------|
| `hw/misc/sst_mmio_bridge.c` | Sysmode `-device sst-mmio-bridge` — guest MMIO loads/stores block until SST responds; with `irq-count=N` also polls the reverse IRQ mailbox on a virtual-time timer and drives interrupt-controller GPIO inputs (SST-device IRQ injection) |
| `quetz_ipc_client.c` | Standalone shared-memory IPC client (no SST dependency); includes the seqlock IRQ-slot drain (`quetz_ipc_irq_drain`) |
| `include/quetz/quetz_ipc_{client,types}.h` | C mirror of the Quetz IPC layout (mailbox + per-(vcore, line) IRQ slots) |
| `linux-user/sst_mmio.{c,h}` | Usermode (P6): PROT_NONE aperture + SIGSEGV routing to the same sync mailbox |

Patches (`qemu-overlay/patches/`, ordered), plus anchor-based idempotent
edits made directly by `apply-qemu-overlay.sh`:

| Patch | Touches |
|-------|---------|
| `hw-misc-meson.patch` | registers the bridge sources with the softmmu build |
| `linux-user-meson.patch` | registers the usermode sources |
| `linux-user-main.patch` | `-sst-mmio-range` command-line option |
| `linux-user-signal.patch` | SIGSEGV hook for the usermode aperture |
| `qemu-options.def.patch` | option table entry |
| (inline edit) `hw/m68k/mcf_intc.c` | exposes the 64 INTC inputs as qdev GPIOs so the bridge can inject IRQs by line number |
| (inline edits) `linux-user/{meson.build,main.c,signal.c}` | usermode wiring for the pieces above |

Consumers: the Quetz launcher passes
`-device sst-mmio-bridge,shmname=...,base=...,size=...` (sysmode) or
`-sst-mmio-range ...` (usermode) when `QUETZ_MMIO_PAYLOAD=1`, and appends
`,irq-count=N[,irq-poll-ns=...][,intc-type=...]` to the sysmode bridge when
`QUETZ_IRQ_LINES` is set (SST-device IRQ injection; `intc-type` defaults to
`mcf-intc`).

**Rebuild procedure** (e.g. after editing the overlay or bumping
`QEMU_VERSION`): the QEMU build is one cached Docker layer — rerun
`docker build --target build ...` and it rebuilds automatically when the
overlay directory or version ARG changes. The shared-memory ABI the bridge
compiles against is exported by the element
(`$SST_PREFIX/include/sst/elements/quetz/quetz_ipc_types.h`); keep the
overlay's copy in sync when the IPC structs change.

Long-term option: upstream `sst-mmio-bridge` to QEMU to retire the fork —
this pinning doc is the prerequisite inventory for that conversation.

---

## Repo contents

```
quetz-docker/
├── Dockerfile                  # Ubuntu 24.04 image: QEMU + SST + Quetz (lightweight)
├── Dockerfile.balar            # CUDA 11.7 + GPGPU-Sim + SST + Balar (+ Quetz if present)
├── build-and-test.sh           # Build quetz image + run Quetz testsuite
├── build-and-test-balar.sh     # Build balar image + run Balar testsuite
├── run-quetz-tests.sh          # In-container Quetz test driver
├── run-balar-tests.sh          # In-container Balar test driver
├── README-balar.md             # Balar / QuetzTestCPU contract test guide
├── rebuild-quetz-usermode-gpu.sh  # Fast libquetz rebuild + GPU tests
├── qemu-overlay/               # QEMU 9.2.1 MMIO bridge overlay
│   ├── apply-qemu-overlay.sh
│   ├── hw/misc/sst_mmio_bridge.c
│   ├── quetz_ipc_client.c
│   └── include/quetz/
└── README.md                   # this file
```

---

## Troubleshooting

**Build context error (`COPY sst-core: not found`)**  
Run `docker build` from the **workspace root**, not from inside `quetz-docker/`:

```bash
cd ~/dev/quetz-workspace
docker build -t raptor-quetz-test -f quetz-docker/Dockerfile .
```

**`sst-mmio-bridge: failed to attach shmem (errno=2)`**  
The bridge opens the Quetz shared-memory segment by name. This requires a matching SST-side `expectedChildren=2` fix in `quetz_qemu_frontend.cc` (included in recent Quetz branches). Rebuild the image after pulling that change.

**Tests pass in Docker but fail on a stale image**  
Mounting `sst-elements/` does not rebuild `libquetz.so`. Run a full `./quetz-docker/build-and-test.sh` after C++ changes.

**Out of memory during build**  
The Dockerfile uses `make -j2`. If the build still OOMs, edit the Dockerfile temporarily to `-j1`.

**Sysmode firmware build skipped**  
The container includes `riscv64-linux-gnu-gcc`. If firmware binaries are missing, run the test script inside the container or build manually:

```bash
docker run --rm -it -v "$(pwd)/sst-elements:/src/sst-elements" raptor-quetz-test bash
cd /src/sst-elements/src/sst/elements/quetz/tests/sysmode/firmware
RV64_CC=riscv64-linux-gnu-gcc ./build.sh
```

---

## Further reading

- Quetz testing guide: `sst-elements/src/sst/elements/quetz/TESTING.md`
- Quetz element overview: `sst-elements/src/sst/elements/quetz/QUETZ_OUTLINE.md`
