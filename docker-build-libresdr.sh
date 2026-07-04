#!/bin/bash
# LibreSDR (Zynq-7020) GPS timing builder. Runs inside the Docker image.
set -euo pipefail

PORT_REPO="https://github.com/hz12opensource/libresdr.git"
PORT_COMMIT="380307610ba56403268c664afddba88bc9d326b3"
FW_REPO="https://github.com/analogdevicesinc/plutosdr-fw.git"
FW_COMMIT="0359a0b9a474567ab658619f3edf53ac65594f5a" # v0.38
BASE_RELEASE="https://github.com/hz12opensource/libresdr/releases/download/v0.38/baseclock_cpu750_ddr525.tar.gz"

CACHE=/build/src
PORT="$CACHE/libresdr-port"
FW="$CACHE/plutosdr-fw_0.38_libre"
OUT=/build/output

info() { printf '\033[0;32m[INFO]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

clone_pinned() {
    local url="$1" commit="$2" dir="$3"
    if [ ! -d "$dir/.git" ]; then
        rm -rf "$dir"
        git clone --no-checkout "$url" "$dir"
    fi
    git -C "$dir" fetch --depth=1 origin "$commit"
    git -C "$dir" reset --hard "$commit"
    git -C "$dir" clean -ffd
}

mkdir -p "$CACHE" "$OUT"
info "Preparing pinned LibreSDR sources"
clone_pinned "$PORT_REPO" "$PORT_COMMIT" "$PORT"
clone_pinned "$FW_REPO" "$FW_COMMIT" "$FW"

cd "$FW"
git submodule sync --recursive
git submodule update --init --depth=1 hdl linux u-boot-xlnx buildroot
for sub in hdl linux u-boot-xlnx buildroot; do
    git -C "$sub" reset --hard
    git -C "$sub" clean -ffd
done

git apply "$PORT/patches/fw.diff"
git -C hdl apply "$PORT/patches/hdl.diff"
git -C linux apply "$PORT/patches/linux.diff"
git -C u-boot-xlnx apply "$PORT/patches/u-boot-xlnx.diff"
git -C buildroot apply "$PORT/patches/buildroot.diff"

python3 /build/boards-src/libresdr/apply_overlay.py "$FW" /build/hdl-src/pps_counter

if [ "${PREPARE_HDL:-0}" = 1 ]; then
    info "Exporting prepared Vivado tree to output/libresdr-hdl"
    rm -rf "$OUT/libresdr-hdl"
    mkdir -p "$OUT/libresdr-hdl"
    cp -a hdl/. "$OUT/libresdr-hdl/"
    printf '%s\n' "$PORT_COMMIT" > "$OUT/libresdr-hdl/LIBRESDR_PORT_COMMIT"
    printf '%s\n' "$FW_COMMIT" > "$OUT/libresdr-hdl/PLUTOSDR_FW_COMMIT"
    info "Run tools/build-libresdr-hdl.ps1, then rebuild with --prebuilt-bit"
    exit 0
fi

[ -n "${PREBUILT_BIT:-}" ] || die \
    "LibreSDR requires --prebuilt-bit. First run --prepare-hdl and tools/build-libresdr-hdl.ps1."
[ -f "$PREBUILT_BIT" ] || die "Prebuilt bitstream not found: $PREBUILT_BIT"

# Kernel nodes/config were installed by apply_overlay.py. Configure the common
# timing packages and services in the LibreSDR Buildroot.
GPS_UART=/dev/ttyUL0 \
BOARD_NAME=libresdr \
BR_CONFIG=buildroot/configs/zynq_libre_defconfig \
ROOTFS_BOARD_DIR=buildroot/board/libre \
    sh /build/boards-src/common/configure-gps-rootfs.sh

# A prebuilt Windows Vivado bitstream is sufficient for the FIT image. The PS
# configuration remains the stock LibreSDR configuration because UART is AXI.
mkdir -p build
cp "$PREBUILT_BIT" build/system_top.bit
touch build/system_top.bit

export TARGET=libre
# Upstream's optional legal-info step downloads package metadata from legacy
# mirrors at build time. It is not part of the firmware payload and can hang
# otherwise reproducible builds when those mirrors are unavailable.
export SKIP_LEGAL=1
info "Building LibreSDR kernel, DTB, rootfs, U-Boot and FIT firmware"
make -j"$(nproc)" \
    build/zImage build/zynq-libre.dtb build/rootfs.cpio.gz \
    build/u-boot.elf build/uboot-env.txt
touch build/system_top.bit
make -j"$(nproc)" build/libre.frm build/libre.dfu

# Seed SD-only boot files with the known-good upstream FSBL. BOOT.bin is
# deliberately finalized by Windows bootgen after inserting our bitstream.
BASE_TAR="$CACHE/baseclock_cpu750_ddr525.tar.gz"
[ -f "$BASE_TAR" ] || curl -L --fail --retry 3 "$BASE_RELEASE" -o "$BASE_TAR"
BASE_DIR="$CACHE/base-release"
rm -rf "$BASE_DIR"
mkdir -p "$BASE_DIR"
tar -xzf "$BASE_TAR" -C "$BASE_DIR"

SD="$OUT/libresdr-sd"
rm -rf "$SD"
mkdir -p "$SD"
cp "$BASE_DIR/build_sdimg/fsbl.elf" "$SD/"
cp build/system_top.bit "$SD/"
cp build/u-boot.elf "$SD/"
cp linux/arch/arm/boot/uImage "$SD/"
cp build/zynq-libre.dtb "$SD/devicetree.dtb"
cp build/uboot-env.txt "$SD/uEnv.txt"
cp build/rootfs.cpio.gz "$SD/ramdisk.image.gz"
mkimage -A arm -T ramdisk -C gzip -d "$SD/ramdisk.image.gz" "$SD/uramdisk.image.gz"
printf 'img : {[bootloader] fsbl.elf system_top.bit u-boot.elf}\n' > "$SD/boot.bif"
cp build/libre.frm build/libre.dfu "$OUT/"

sh /build/boards-src/libresdr/validate_sd.sh "$SD"

info "Linux build complete."
info "Finalize SD BOOT.bin on Windows:"
info "  powershell -File tools/finalize-libresdr-sd.ps1"
