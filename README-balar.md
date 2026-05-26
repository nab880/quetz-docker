# Balar integration tests (Docker)

Validates [Balar](https://github.com/sstsimulator/sst-elements/tree/devel/src/sst/elements/balar) + GPGPU-Sim on the **`balar-integration`** branch. These tests demonstrate the MMIO + scratch + DMA contract Quetz will use when wiring `balar.balarMMIO` (see `quetz/QUETZ_OUTLINE.md` §4.3.2).

## Prerequisites

- Docker with enough disk (~15 GB image) and RAM for GPGPU-Sim builds
- **Apple Silicon (M1/M2/M3):** the build script forces `--platform linux/amd64` because GPGPU-Sim’s accelwattch uses x86 SSE flags. Emulation is slower but required.
- **Note:** upstream `balar/.ignore` skips the element during `./autogen.sh`; `Dockerfile.balar` removes that file so Balar is configured with CUDA/GPGPU-Sim.
- Optional: `UPDATE_GOLD=1` to refresh `tests/refFiles/*.out` after intentional stat changes

## Quick start

From the **workspace root** (parent of `sst-core/`, `sst-elements/`, `quetz-docker/`):

```bash
cd sst-elements && git checkout balar-integration && cd ..

./quetz-docker/build-and-test-balar.sh
```

## Image contents

| Layer | Purpose |
|-------|---------|
| `nvidia/cuda:11.7.1-devel-ubuntu22.04` | CUDA toolkit for Balar configure |
| GPGPU-Sim (`accel-sim/gpgpu-sim_distribution`, SST mode) | GPU timing model behind `balarMMIO` |
| QEMU 9.2 + plugins | Quetz tests when the `quetz` element is present in `sst-elements` |
| SST core + elements | `--with-cuda` + `--with-gpgpusim` enables **balar** |

Image name default: `raptor-balar-test` (`RAPTOR_BALAR_IMAGE` overrides).

## Environment variables (in container)

| Variable | Default | Used by |
|----------|---------|---------|
| `CUDA_INSTALL_PATH` | `/usr/local/cuda` | SST configure, tests |
| `GPGPUSIM_ROOT` | `/opt/gpgpu-sim` | SST configure, runtime `setup_environment` |
| `GPU_ARCH` | `sm_70` | Vanadis CUDA builds (optional) |
| `NVCC_PATH` | set by testsuite from `which nvcc` | `balar_trace` compile |
| `LLVM_INSTALL_PATH` | unset in CI | Vanadis `vecadd` test (skipped if missing) |
| `RISCV_TOOLCHAIN_INSTALL_PATH` | unset in CI | Vanadis `vecadd` test (skipped if missing) |

## Test matrix

The default image keeps the dependency surface tiny: it builds only the SST elements that Balar itself ships (`balar`, `memHierarchy`, `mmu`). Tests that require the full GPU memory hierarchy (`shogun`, `merlin`, …) auto-skip via `BalarTestCase.balar_basic_unittest` until those elements are enabled in the image.

### Tier-0 smoke (always runs)

| Test | Demonstrates |
|------|----------------|
| `test_balar_sst_info_registers_components` | Element built; ELI registers `balar.balarMMIO` |
| `test_balar_quetz_testcpu_registered` | ELI registers `balar.QuetzTestCPU` |

### Skipped by default (need full GPU mem hierarchy)

| Test | SDL | Why skipped |
|------|-----|-------------|
| `test_balar_contract_doorbell` | `testBalar-doorbell.py` | needs `shogun.ShogunXBar` for `balarBlock.build()` |
| `test_balar_contract_malloc_free` | `testBalar-malloc-free.py` | same |
| `test_balar_contract_wide_packet` | `testBalar-wide-packet.py` | same |
| `test_quetz_balar_doorbell` | `testQuetz-balar-doorbell.py` | same |
| `test_quetz_balar_malloc_free` | `testQuetz-balar-malloc-free.py` | same |
| `test_quetz_balar_wide_packet` | `testQuetz-balar-wide-packet.py` | same |
| `test_balar_runvecadd_testcpu` | `testBalar-testcpu.py` | same |
| `test_balar_vanadis_clang_vecadd` | `testBalar-vanadis.py` | also needs LLVM + RISC-V toolchain |

To enable the integration tests, edit `Dockerfile.balar` and add `rm -f src/sst/elements/<name>/.ignore` for the elements you need (at minimum `shogun`; `merlin` for the BalarTestCPU router topology), then rebuild the image.

Pass criteria for the integration tests (when enabled): stats file exists, no `FATAL` in stderr, stdout contains `Test Completed Successfuly`.

## FlushAddr-before-doorbell contract

QuetzTestCPU sequence per CUDA call:

1. Chunked `Write` of encoded packet (+ optional payload) to `scratch_mem_addr` on **`cache_link`**
2. `FlushAddr(line, cache_line_size, inv=true, depth=1)` for each cache line covering the scratch region
3. After all `FlushResp`, `Write` scratch pointer to **`mmio_addr`** on **`mmio_link`** (doorbell)
4. `balarMMIO` DMA-reads scratch from DRAM (consistent after L1 flush)

### Negative experiment (proves flush is required)

Temporarily remove the `FlushAddr` loop in `quetzTestCPU.cc` and rerun `test_quetz_balar_malloc_free` — expect stale scratch / decode failure. Ship tests with flush **enabled**.

## Trace files

Under `balar/tests/traces/`:

- `doorbell_malloc.trace` — single `cudaMalloc(64)`
- `malloc_free.trace` — `cudaMalloc` + `cudaFree`
- `wide_memcpy_d2h.trace` — 4 KiB H2D + D2H (payload files generated at test setup)

## Updating gold files

```bash
UPDATE_GOLD=1 ./quetz-docker/build-and-test-balar.sh
```

## Quetz tests (same image)

When `sst-elements` includes the `quetz` element:

```bash
docker run --rm \
  -v "$(pwd)/sst-elements:/src/sst-elements" \
  raptor-balar-test \
  /usr/local/bin/run-quetz-tests.sh
```

For a lighter Quetz-only image (Ubuntu 24.04, no CUDA/GPGPU-Sim), use `./quetz-docker/build-and-test.sh` and `Dockerfile` instead.

## Expected runtime

- First image build: 30–90 minutes (GPGPU-Sim + QEMU + SST)
- Incremental rebuild (source volume mount): seconds for Python-only changes
- Balar testsuite: 10–40 minutes depending on GPU config (`gpu-v100-mem.cfg`)
