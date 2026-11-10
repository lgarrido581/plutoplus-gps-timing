#!/bin/bash
# Assemble the Fishball7020 SD-card boot set from a finished plutosdr-fw build.
# Usage: make_sd.sh <plutosdr-fw root> <vendor dir> <out dir>
#
# BOOT.bin = the stock FSBL + our system_top.bit + the stock U-Boot, both cut out
# of the stock BOOT.bin (OpenSourceSDRLab's SD set, pinned in vendor.lock). That
# FSBL's ps7_init is the board's own (DDR, MIO), and that U-Boot already SD-boots
# it with the stock uEnv.txt; the kernel, device tree and ramdisk it loads are ours.
set -euo pipefail

FW="$1"; VENDOR="$2"; OUT="$3"
SDV="$VENDOR/sdlab/firmware/SD Card Firmware"
MKIMAGE="$FW/u-boot-xlnx/tools/mkimage"
command -v bootgen >/dev/null || { echo "make_sd: bootgen not on PATH (needs --vivado)" >&2; exit 1; }
[ -x "$MKIMAGE" ] || MKIMAGE=mkimage

rm -rf "$OUT"; mkdir -p "$OUT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

python3 "$(dirname "$0")/split_boot.py" "$SDV/BOOT.bin" "$WORK"
cp "$FW/build/system_top.bit" "$WORK/system_top.bit"
cat > "$WORK/boot.bif" <<'EOF'
the_ROM_image:
{
	[bootloader] fsbl.elf
	system_top.bit
	[load=0x04000000, startup=0x04000000] u-boot.bin
}
EOF
(cd "$WORK" && bootgen -arch zynq -image boot.bif -o "$OUT/BOOT.bin" -w on >/dev/null)

# The new BOOT.bin must carry the stock FSBL and U-Boot byte for byte.
python3 "$(dirname "$0")/split_boot.py" "$OUT/BOOT.bin" "$WORK/check" >/dev/null
cmp -s "$WORK/fsbl.elf" "$WORK/check/fsbl.elf" && cmp -s "$WORK/u-boot.bin" "$WORK/check/u-boot.bin" \
    || { echo "make_sd: FSBL/U-Boot changed in the repacked BOOT.bin" >&2; exit 1; }

"$MKIMAGE" -A arm -O linux -T kernel -C none -a 0x8000 -e 0x8000 -n "Linux" \
    -d "$FW/build/zImage" "$OUT/uImage" >/dev/null
"$MKIMAGE" -A arm -T ramdisk -C gzip -n "Ramdisk" \
    -d "$FW/build/rootfs.cpio.gz" "$OUT/uramdisk.image.gz" >/dev/null
cp "$FW/build/zynq-pluto-sdr-revc.dtb" "$OUT/devicetree.dtb"
cp "$SDV/uEnv.txt" "$OUT/uEnv.txt"

(cd "$OUT" && sha256sum BOOT.bin uImage uramdisk.image.gz devicetree.dtb uEnv.txt > SHA256SUMS)
echo "  SD set in $OUT:"; ls -l "$OUT" | sed 's/^/    /'
