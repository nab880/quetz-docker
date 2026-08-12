# SST + Quetz images (user-mode and system-mode QEMU).
#
# Two targets, built from the workspace root (parent of this repo, with
# sst-core/ and sst-elements/):
#
#   test env (toolchain + /build tree + testsuite):
#     docker build --target build -t raptor-quetz-test -f quetz-docker/Dockerfile .
#     ./quetz-docker/build-and-test.sh
#     UPDATE_GOLD=1 ./quetz-docker/build-and-test.sh
#
#   user runtime (slim: sim + cross compilers + quetz-run; no build tree):
#     docker build --target runtime -t quetz-sim -f quetz-docker/Dockerfile .
#     ./quetz-docker/quetz-run              # runs the ColdFire system demo
#
# NOTE: images bake the element at build time — rebuild after sst-elements
# changes (the test scripts rebuild from the /src mount; quetz-run does not).

FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90 AS build

ENV DEBIAN_FRONTEND=noninteractive
ENV SST_PREFIX=/opt/sst
ENV PATH="${SST_PREFIX}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${SST_PREFIX}/lib"

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    bison \
    build-essential \
    ca-certificates \
    curl \
    doctest-dev \
    flex \
    git \
    libcap-ng-dev \
    libglib2.0-dev \
    libopenmpi-dev \
    libpixman-1-dev \
    libslirp-dev \
    libtool \
    libtool-bin \
    ninja-build \
    openmpi-bin \
    pkg-config \
    python3 \
    python3-dev \
    python3-blessings \
    python3-pip \
    python3-pygments \
    zlib1g-dev \
    gcc-riscv64-linux-gnu \
    libc6-dev-riscv64-cross \
    gcc-m68k-linux-gnu \
    && mkdir -p /opt/quetz \
    && dpkg-query -W > /opt/quetz/build-packages.txt \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu/Fedora packages do not ship qemu-plugin.h — build QEMU 9.2 with plugins.
ARG QEMU_VERSION=9.2.1
ARG QEMU_SHA256=72874fe9c395ced0c7fd7c22c43744072697f7ee1926a72237bd81784b2faf62
ARG QEMU_TARGET_LIST=riscv64-softmmu,aarch64-softmmu,arm-softmmu,i386-softmmu,m68k-softmmu,riscv64-linux-user,aarch64-linux-user,x86_64-linux-user
ARG BUILD_JOBS=2
ENV QEMU_PREFIX=/opt/qemu
COPY sst-elements/src/sst/elements/quetz/qemu-overlay /docker/qemu-overlay
# Host-fetched tarball under quetz-docker/cache/ (corp TLS interception breaks
# curl→download.qemu.org inside the build). Keep checksum verification.
COPY quetz-docker/cache/qemu-9.2.1.tar.xz /tmp/qemu-9.2.1.tar.xz
RUN echo "${QEMU_SHA256}  /tmp/qemu-${QEMU_VERSION}.tar.xz" | sha256sum -c - \
    && tar xJf "/tmp/qemu-${QEMU_VERSION}.tar.xz" -C /tmp \
    && cd "/tmp/qemu-${QEMU_VERSION}" \
    && sh /docker/qemu-overlay/apply-qemu-overlay.sh "/tmp/qemu-${QEMU_VERSION}" \
    && ./configure \
         --prefix="${QEMU_PREFIX}" \
         --target-list="${QEMU_TARGET_LIST}" \
         --enable-plugins \
    && make -j"${BUILD_JOBS}" \
    && make -j"${BUILD_JOBS}" plugins \
    && make install \
    && mkdir -p "${QEMU_PREFIX}/include" \
    && (test -f "${QEMU_PREFIX}/include/qemu-plugin.h" \
        || cp include/plugins/qemu-plugin.h "${QEMU_PREFIX}/include/qemu-plugin.h") \
    && mkdir -p "${QEMU_PREFIX}/lib/qemu/plugins" \
    # Parenthesized so the optional contrib-plugin copy is the ONLY thing the
    # `|| true` forgives — unparenthesized it swallowed failures of the whole
    # && chain, letting a broken QEMU build produce a "successful" layer.
    && (cp -a build/contrib/plugins/*.so "${QEMU_PREFIX}/lib/qemu/plugins/" 2>/dev/null \
        || cp -a contrib/plugins/*.so "${QEMU_PREFIX}/lib/qemu/plugins/" 2>/dev/null \
        || true) \
    && rm -rf "/tmp/qemu-${QEMU_VERSION}" "/tmp/qemu-${QEMU_VERSION}.tar.xz"

ENV QEMU_PLUGIN_DIR="${QEMU_PREFIX}/lib/qemu/plugins"

# Tests look for QEMU under $SST_PREFIX/bin first.
RUN mkdir -p "${SST_PREFIX}/bin" "${SST_PREFIX}/lib" "${SST_PREFIX}/libexec" \
    && for emulator in qemu-riscv64 qemu-aarch64 qemu-x86_64 \
        qemu-system-riscv64 qemu-system-aarch64 qemu-system-i386 \
        qemu-system-arm qemu-system-m68k; do \
        if [ -x "${QEMU_PREFIX}/bin/${emulator}" ]; then \
            ln -sf "${QEMU_PREFIX}/bin/${emulator}" "${SST_PREFIX}/bin/${emulator}"; \
        fi; \
    done

WORKDIR /src

# Copy sources (build context is workspace root containing sst-core/, sst-elements/, quetz-docker/)
COPY sst-core /src/sst-core
COPY sst-elements /src/sst-elements

# Sanity: the build must have produced real system emulators. No pipe (the
# old `qemu-system-x86_64 --version | head -1` always passed: x86_64-softmmu
# is not even in the target list and head's exit status masked the 127).
RUN "${QEMU_PREFIX}/bin/qemu-system-m68k" --version \
    && test -f "${QEMU_PREFIX}/include/qemu-plugin.h"

# --- SST-Core ---
RUN cd /src/sst-core \
    && ./autogen.sh \
    && mkdir -p /build/sst-core && cd /build/sst-core \
    && /src/sst-core/configure --prefix="${SST_PREFIX}" \
    && make -j"${BUILD_JOBS}" install

# --- SST-Elements (only the Raptor runtime dependencies) ---
# merlin is required by the GPU/accelerator compute decks
# (basic_quetz_gpu_compute*.py use merlin.hr_router / merlin.singlerouter for
# the on-chip router); without it those decks fatal with
# "can't find requested component 'merlin.hr_router'".
RUN find /src/sst-elements/src/sst/elements -mindepth 1 -maxdepth 1 -type d \
         ! -name memHierarchy ! -name mmu ! -name quetz ! -name merlin \
         -exec touch '{}/.ignore' \; \
    && cd /src/sst-elements \
    && ./autogen.sh \
    && find /src/sst-elements/src/sst/elements/quetz -name '*.lo' -delete \
    && mkdir -p /build/sst-elements && cd /build/sst-elements \
    && /src/sst-elements/configure \
         --prefix="${SST_PREFIX}" \
         --with-sst-core="${SST_PREFIX}" \
         --with-qemu-prefix="${QEMU_PREFIX}" \
         --without-pin \
    && make -j"${BUILD_JOBS}" install

# Register element libraries and test paths.
RUN "${SST_PREFIX}/bin/sst-register" SST_ELEMENT_SOURCE quetz=/src/sst-elements/src/sst/elements/quetz \
    && "${SST_PREFIX}/bin/sst-register" SST_ELEMENT_TESTS quetz=/src/sst-elements/src/sst/elements/quetz/tests

COPY tools /opt/quetz/tools
COPY schemas /opt/quetz/schemas
COPY quetz-docker/run-quetz-tests.sh /usr/local/bin/run-quetz-tests.sh
COPY quetz-docker/quetz-run /usr/local/bin/quetz-run
COPY quetz-docker/quetz-result.py /usr/local/bin/quetz-result.py
RUN chmod +x /usr/local/bin/run-quetz-tests.sh /usr/local/bin/quetz-run /usr/local/bin/quetz-result.py

WORKDIR /src/sst-elements/src/sst/elements/quetz/tests
CMD ["/usr/local/bin/run-quetz-tests.sh"]

# ---------------------------------------------------------------------------
# Runtime image (quetz-sim): everything needed to RUN simulations and build
# guest firmware — no autotools, no /build tree, no testsuite scaffolding.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV SST_PREFIX=/opt/sst
ENV QEMU_PREFIX=/opt/qemu
ENV PATH="${SST_PREFIX}/bin:${QEMU_PREFIX}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${SST_PREFIX}/lib"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    gcc-m68k-linux-gnu \
    gcc-riscv64-linux-gnu \
    libc6-dev-riscv64-cross \
    libcap-ng0 \
    libglib2.0-0 \
    libnuma1 \
    libpixman-1-0 \
    libpython3.12 \
    libslirp0 \
    libstdc++6 \
    openmpi-bin \
    python3 \
    zlib1g \
    && mkdir -p /opt/quetz \
    && dpkg-query -W > /opt/quetz/runtime-packages.txt \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/qemu /opt/qemu
COPY --from=build /opt/sst /opt/sst
COPY --from=build /opt/quetz /opt/quetz
# The element source tree: decks, test helpers, firmware + fixtures, docs.
# (sst-register paths in /opt/sst/etc point here.)
COPY --from=build /src/sst-elements/src/sst/elements/quetz /src/sst-elements/src/sst/elements/quetz

COPY quetz-docker/quetz-run /usr/local/bin/quetz-run
COPY quetz-docker/BSP-HONESTY.txt /usr/local/bin/BSP-HONESTY.txt
COPY quetz-docker/quetz-result.py /usr/local/bin/quetz-result.py
RUN chmod +x /usr/local/bin/quetz-run /usr/local/bin/quetz-result.py

WORKDIR /work
CMD ["quetz-run", "--help"]
