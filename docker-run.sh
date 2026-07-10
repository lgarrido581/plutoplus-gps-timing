#!/bin/bash
set -o pipefail
# Git Bash/MSYS otherwise rewrites Docker's Linux-side bind destinations and
# creates malformed host directories such as "output;C".
case "${MSYSTEM:-}" in
    MINGW*|MSYS*) export MSYS_NO_PATHCONV=1 ;;
esac
# =============================================================================
# Build GPS timing firmware in Docker.
# Run this from the directory containing Dockerfile + docker-build-inner.sh.
#
# Usage:
#   ./docker-run.sh                        # Pluto+ (backward-compatible default)
#   ./docker-run.sh --target libresdr --prepare-hdl
#   ./docker-run.sh --target libresdr --prebuilt-bit output/libresdr-hdl/system_top.bit
#   ./docker-run.sh --vivado /home/you/Xilinx   # mount your Vivado install (full build w/ boot.frm)
#       pass the path you installed Vivado to; it is mounted at the SAME path inside the container.
#
# Output firmware lands in ./output/
# =============================================================================

IMAGE="gps-timing-builder"
VIVADO_HOST=""

# Parse args
EXTRA_ENV=""
PREBUILT_BIT_HOST=""
TARGET="plutoplus"
PREPARE_HDL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --vivado) VIVADO_HOST="$2"; shift 2 ;;
        --prepare-hdl) PREPARE_HDL=1; shift ;;
        --gpio-test) EXTRA_ENV="$EXTRA_ENV -e PPS_GPIO_TEST=1"; shift ;;  # I/O voltage test build -> pluto-gpiotest.frm
        --hwlatch)   EXTRA_ENV="$EXTRA_ENV -e PPS_HWLATCH=1";   shift ;;  # hardware-latch (F20 PPS input)
        # Reuse a known-good PL bitstream (e.g. extracted from a prior release's pluto.frm)
        # instead of synthesizing it -> no Vivado needed for a rootfs/script-only release.
        --prebuilt-bit) PREBUILT_BIT_HOST="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

case "$TARGET" in
    plutoplus|libresdr) ;;
    *) echo "Invalid --target '$TARGET' (expected plutoplus or libresdr)"; exit 1 ;;
esac

[ "$TARGET" = "plutoplus" ] && [ "$PREPARE_HDL" = 1 ] \
    && { echo "--prepare-hdl is only valid for --target libresdr"; exit 1; }
[ "$TARGET" = "plutoplus" ] && EXTRA_ENV="$EXTRA_ENV -e BUILD_TARGET=plutoplus"
[ "$TARGET" = "libresdr" ] && EXTRA_ENV="$EXTRA_ENV -e BUILD_TARGET=libresdr"
[ "$PREPARE_HDL" = 1 ] && EXTRA_ENV="$EXTRA_ENV -e PREPARE_HDL=1"

# Separate named volumes prevent one target from wiping the other target's clone.
SRC_VOLUME="gps-timing-${TARGET}-src-cache"
docker volume create "$SRC_VOLUME" &>/dev/null

# Create output dir
mkdir -p output

# Build the Docker image (only rebuilds if Dockerfile changed)
echo "[*] Building Docker image..."
docker build -t "$IMAGE" .

# Construct Vivado mount if provided.
# IMPORTANT: mount at the SAME absolute path inside the container. Vivado's
# settings64.sh hardcodes its install path, so mounting it elsewhere (e.g.
# /opt/Xilinx) breaks it -> vivado fails -> the build silently downloads the XSA.
VIVADO_MOUNT=""
if [ -n "$VIVADO_HOST" ]; then
    [ "$TARGET" = "libresdr" ] && {
        echo "Native Windows Vivado cannot run in the Linux container."
        echo "Use --prepare-hdl, build with tools/build-libresdr-hdl.ps1, then --prebuilt-bit."
        exit 1
    }
    echo "[*] Mounting Vivado from: $VIVADO_HOST (same path in container)"
    # --tmpfs /sys: Vivado's WebTalk/license host-scan calls libudev
    # udev_enumerate_scan_devices, which corrupts the heap scanning the
    # container's /sys (crashes on 20.04 and 22.04 alike). An empty tmpfs /sys
    # gives it nothing to choke on.
    VIVADO_MOUNT="-v ${VIVADO_HOST}:${VIVADO_HOST}:ro -e VIVADO_PATH=${VIVADO_HOST} --tmpfs /sys"
fi

# Mount a prebuilt bitstream (reuse) into the container if provided.
PREBUILT_MOUNT=""
if [ -n "$PREBUILT_BIT_HOST" ]; then
    [ -f "$PREBUILT_BIT_HOST" ] || { echo "--prebuilt-bit: file not found: $PREBUILT_BIT_HOST"; exit 1; }
    echo "[*] Reusing prebuilt bitstream: $PREBUILT_BIT_HOST (no Vivado synth)"
    PREBUILT_MOUNT="-v $(realpath "$PREBUILT_BIT_HOST"):/build/prebuilt/system_top.bit:ro -e PREBUILT_BIT=/build/prebuilt/system_top.bit"
fi

echo "[*] Starting build container (logging to build.log)..."
INNER_SCRIPT="docker-build-inner.sh"
[ "$TARGET" = "libresdr" ] && INNER_SCRIPT="docker-build-libresdr.sh"
docker run --rm \
    -v "$(pwd)/$INNER_SCRIPT:/build/scripts/docker-build-inner.sh:ro" \
    -v "$(pwd)/output:/build/output" \
    -v "$SRC_VOLUME:/build/src" \
    -v "$(pwd)/hdl:/build/hdl-src:ro" \
    -v "$(pwd)/services:/build/services-src:ro" \
    -v "$(pwd)/boards:/build/boards-src:ro" \
    $VIVADO_MOUNT \
    $PREBUILT_MOUNT \
    $EXTRA_ENV \
    --name "${TARGET}-gps-build" \
    "$IMAGE" 2>&1 | tee build.log
