# SST + Quetz test environment (user-mode and system-mode QEMU).
#
# Build from workspace root (parent of this repo, with sst-core/ and sst-elements/):
#   docker build -t raptor-quetz-test -f quetz-docker/Dockerfile .
# Run:
#   ./quetz-docker/build-and-test.sh
# Gold:
#   UPDATE_GOLD=1 ./quetz-docker/build-and-test.sh

FROM ubuntu:24.04

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
    && rm -rf /var/lib/apt/lists/*

# Ubuntu/Fedora packages do not ship qemu-plugin.h — build QEMU 9.2 with plugins.
ARG QEMU_VERSION=9.2.1
ENV QEMU_PREFIX=/opt/qemu
COPY quetz-docker/qemu-overlay /docker/qemu-overlay
RUN curl -fsSL "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" \
        | tar xJ -C /tmp \
    && cd "/tmp/qemu-${QEMU_VERSION}" \
    && sh /docker/qemu-overlay/apply-qemu-overlay.sh "/tmp/qemu-${QEMU_VERSION}" \
    && ./configure \
         --prefix="${QEMU_PREFIX}" \
         --target-list=riscv64-softmmu,aarch64-softmmu,arm-softmmu,i386-softmmu,m68k-softmmu,riscv64-linux-user,aarch64-linux-user,x86_64-linux-user \
         --enable-plugins \
    && make -j2 \
    && make -j2 plugins \
    && make install \
    && mkdir -p "${QEMU_PREFIX}/include" \
    && (test -f "${QEMU_PREFIX}/include/qemu-plugin.h" \
        || cp include/plugins/qemu-plugin.h "${QEMU_PREFIX}/include/qemu-plugin.h") \
    && mkdir -p "${QEMU_PREFIX}/lib/qemu/plugins" \
    && cp -a build/contrib/plugins/*.so "${QEMU_PREFIX}/lib/qemu/plugins/" 2>/dev/null \
        || cp -a contrib/plugins/*.so "${QEMU_PREFIX}/lib/qemu/plugins/" 2>/dev/null \
        || true \
    && rm -rf "/tmp/qemu-${QEMU_VERSION}"

ENV QEMU_PLUGIN_DIR="${QEMU_PREFIX}/lib/qemu/plugins"

# Tests look for QEMU under $SST_PREFIX/bin first.
RUN mkdir -p "${SST_PREFIX}/bin" "${SST_PREFIX}/lib" "${SST_PREFIX}/libexec" \
    && ln -sf "${QEMU_PREFIX}/bin/qemu-riscv64"        "${SST_PREFIX}/bin/qemu-riscv64" \
    && ln -sf "${QEMU_PREFIX}/bin/qemu-aarch64"       "${SST_PREFIX}/bin/qemu-aarch64" \
    && ln -sf "${QEMU_PREFIX}/bin/qemu-x86_64"        "${SST_PREFIX}/bin/qemu-x86_64" \
    && ln -sf "${QEMU_PREFIX}/bin/qemu-system-riscv64" "${SST_PREFIX}/bin/qemu-system-riscv64" \
    && ln -sf "${QEMU_PREFIX}/bin/qemu-system-aarch64" "${SST_PREFIX}/bin/qemu-system-aarch64" \
    && ln -sf "${QEMU_PREFIX}/bin/qemu-system-i386"    "${SST_PREFIX}/bin/qemu-system-i386" \
    && ln -sf "${QEMU_PREFIX}/bin/qemu-system-arm"     "${SST_PREFIX}/bin/qemu-system-arm" \
    && ln -sf "${QEMU_PREFIX}/bin/qemu-system-m68k"    "${SST_PREFIX}/bin/qemu-system-m68k"

WORKDIR /src

# Copy sources (build context is workspace root containing sst-core/, sst-elements/, quetz-docker/)
COPY sst-core /src/sst-core
COPY sst-elements /src/sst-elements

RUN "${QEMU_PREFIX}/bin/qemu-system-x86_64" --version | head -1

# --- SST-Core ---
RUN cd /src/sst-core \
    && ./autogen.sh \
    && mkdir -p /build/sst-core && cd /build/sst-core \
    && /src/sst-core/configure --prefix="${SST_PREFIX}" \
    && make -j2 install

# --- SST-Elements (memHierarchy + quetz; other elements optional) ---
RUN cd /src/sst-elements \
    && ./autogen.sh \
    && find /src/sst-elements/src/sst/elements/quetz -name '*.lo' -delete \
    && mkdir -p /build/sst-elements && cd /build/sst-elements \
    && /src/sst-elements/configure \
         --prefix="${SST_PREFIX}" \
         --with-sst-core="${SST_PREFIX}" \
         --with-qemu-prefix="${QEMU_PREFIX}" \
         --without-pin \
    && make -j2 install

# Register element libraries and test paths.
RUN "${SST_PREFIX}/bin/sst-register" SST_ELEMENT_SOURCE quetz=/src/sst-elements/src/sst/elements/quetz \
    && "${SST_PREFIX}/bin/sst-register" SST_ELEMENT_TESTS quetz=/src/sst-elements/src/sst/elements/quetz/tests

COPY quetz-docker/run-quetz-tests.sh /usr/local/bin/run-quetz-tests.sh
RUN chmod +x /usr/local/bin/run-quetz-tests.sh

WORKDIR /src/sst-elements/src/sst/elements/quetz/tests
CMD ["/usr/local/bin/run-quetz-tests.sh"]
