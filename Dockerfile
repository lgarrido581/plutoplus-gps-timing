# =============================================================================
# Pluto+ GPS Timing Firmware Builder
# Ubuntu 22.04 + ARM cross-compiler + all build deps
#
# Vivado is NOT included — mount it from the host at runtime if needed.
# All GPS changes (DTS, kernel config, gpsd/chrony) build without Vivado.
# =============================================================================
# 22.04 (not 20.04): Vivado 2023.2's host-info WebTalk scan crashes in 20.04's
# libudev inside a container (udev_enumerate_scan_devices SIGABRT). 22.04's
# libudev is fine and is Vivado 2023.2's supported platform.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV CROSS_COMPILE=arm-linux-gnueabihf-
ENV ARCH=arm

# Build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Cross-compiler
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf \
    # Core build tools
    build-essential \
    make \
    git \
    # Kernel build requirements
    bc \
    flex \
    bison \
    libssl-dev \
    libelf-dev \
    # GCC plugin headers (kernel CONFIG_GCC_PLUGINS needs gmp/mpc/mpfr)
    libgmp-dev \
    libmpc-dev \
    libmpfr-dev \
    # Device tree
    device-tree-compiler \
    # U-boot tools
    u-boot-tools \
    # DFU flashing
    dfu-util \
    # Buildroot deps
    unzip \
    rsync \
    python3 \
    python3-pip \
    cpio \
    wget \
    file \
    # Misc
    curl \
    ca-certificates \
    locales \
    zip \
    # Runtime libs so a host Vivado 2023.2 mounted via --vivado can run in-container
    libtinfo5 \
    libncurses5 \
    libx11-6 \
    libxext6 \
    libxrender1 \
    libxtst6 \
    libxi6 \
    libfreetype6 \
    libfontconfig1 \
    x11-utils \
    xvfb \
    && rm -rf /var/lib/apt/lists/*

# Generate locale (buildroot wants it)
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8

# Linaro ARM toolchain — Ubuntu's packaged gcc fails Buildroot's relocatability check
RUN wget -q -O /tmp/linaro.tar.xz \
    https://releases.linaro.org/components/toolchain/binaries/7.3-2018.05/arm-linux-gnueabihf/gcc-linaro-7.3.1-2018.05-x86_64_arm-linux-gnueabihf.tar.xz \
    && tar -xf /tmp/linaro.tar.xz -C /opt/ \
    && rm /tmp/linaro.tar.xz
ENV PATH="/opt/gcc-linaro-7.3.1-2018.05-x86_64_arm-linux-gnueabihf/bin:$PATH"
ENV CROSS_COMPILE=arm-linux-gnueabihf-

# Buildroot's CUSTOM external toolchain defaults the prefix to "arm-linux" (not
# "arm-linux-gnueabihf"), so it looks for arm-linux-gcc which doesn't exist.
# Create arm-linux-* symlinks pointing at the real gnueabihf binaries so the
# toolchain check passes regardless of which prefix Buildroot's syncconfig picks.
RUN cd /opt/gcc-linaro-7.3.1-2018.05-x86_64_arm-linux-gnueabihf/bin && \
    for t in gcc g++ cpp ld ar nm objcopy objdump strip ranlib as \
              addr2line readelf size strings gcov gprof; do \
        src="arm-linux-gnueabihf-${t}"; \
        [ -f "$src" ] && ln -sf "$src" "arm-linux-${t}" || true; \
    done

# Create a non-root build user (Vivado requires non-root on some versions)
RUN useradd -m -s /bin/bash builder
WORKDIR /build
RUN chown builder:builder /build && mkdir -p /build/src && chown builder:builder /build/src

USER builder

# Default: run the build script if present, otherwise drop to shell
CMD ["/bin/bash", "/build/scripts/docker-build-inner.sh"]
