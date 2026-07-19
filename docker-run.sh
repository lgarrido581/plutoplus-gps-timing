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

# Firmware release version = this repo's VERSION file (single source of truth). Passed
# into the build so pluto_zmqd bakes it (-DGPS_TIMING_VERSION) and the login banner shows
# it -- the git-describe VERSION is the fw-0.39 base, not this repo's release tag.
FW_VER="$(cat VERSION 2>/dev/null || echo unknown)"
EXTRA_ENV="$EXTRA_ENV -e GPS_TIMING_VERSION=$FW_VER"

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

# --- Bitstream-source guardrail (prevents silently shipping the WRONG gateware) --------
# A rootfs/services-only rebuild MUST reuse the *validated* bitstream. With neither
# --vivado (full synth) nor --prebuilt-bit given, the build would download/extract an
# unverified stock bit that LACKS the coincident-capture pps_counter -- the radio then
# boots pps=N / GPS-untrusted even though chrony is PPS-locked, and it is NOT obvious why.
# So: default to the committed known-good bit, and REFUSE to build an unverified one.
# Pass --vivado ONLY for an intentional gateware change (then refresh output/working.bit).
if [ -z "$VIVADO_HOST" ] && [ -z "$PREBUILT_BIT_HOST" ] && [ "$PREPARE_HDL" != "1" ]; then
    case "$TARGET" in
        plutoplus) KNOWN_GOOD_BIT="output/working.bit" ;;
        libresdr)  KNOWN_GOOD_BIT="output/libresdr-hdl/system_top.bit" ;;
        *)         KNOWN_GOOD_BIT="" ;;
    esac
    if [ -n "$KNOWN_GOOD_BIT" ] && [ -f "$KNOWN_GOOD_BIT" ]; then
        PREBUILT_BIT_HOST="$KNOWN_GOOD_BIT"
        echo "[*] No --vivado/--prebuilt-bit given -> reusing the known-good bitstream:"
        echo "      $KNOWN_GOOD_BIT   (services/rootfs-only rebuild; use --vivado to change gateware)"
        # output/working.bit is the coincident-capture / hardware-PPS-latch bitstream, so also
        # build its MATCHING services: S70xocorrect (GPS sample-clock discipline) is only written
        # when PPS_HWLATCH=1. Without this, a clean-cache rebuild ships the right bit but silently
        # omits xo_correction. (No synth runs on the --prebuilt-bit path, so the hwlatch-timing
        # caveat that applies to a --vivado build does NOT apply here.)
        if [ "$TARGET" = "plutoplus" ]; then
            case "$EXTRA_ENV" in
                *PPS_HWLATCH*) : ;;
                *) EXTRA_ENV="$EXTRA_ENV -e PPS_HWLATCH=1"
                   echo "      + PPS_HWLATCH=1 (writes the matching S70xocorrect sample-clock service)" ;;
            esac
        fi
    else
        echo "ERROR: no bitstream source, and no known-good bit at '${KNOWN_GOOD_BIT:-<none>}'." >&2
        echo "       Pass --prebuilt-bit <system_top.bit> (reuse) or --vivado <XilinxDir> (full synth)." >&2
        echo "       Refusing to synthesize/download an UNVERIFIED bit -- that ships a radio without" >&2
        echo "       the coincident-capture pps_counter. See RELEASING.md / docs/BUILD.md." >&2
        exit 1
    fi
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
    -v "$(pwd)/test:/build/test-src:ro" \
    $VIVADO_MOUNT \
    $PREBUILT_MOUNT \
    $EXTRA_ENV \
    --name "${TARGET}-gps-build" \
    "$IMAGE" 2>&1 | tee build.log
