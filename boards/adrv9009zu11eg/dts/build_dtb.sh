#!/usr/bin/env bash
# Build system.dtb for ADRV9009-ZU11EG Rev.B + ADRV2CRR-FMC Rev.B with the GPS
# additions. Needs git, cpp and dtc; the repo's builder image has all three:
#
#   docker run --rm -v "$PWD":/w -w /w plutoplus-gps-builder \
#       bash boards/adrv9009zu11eg/dts/build_dtb.sh
#
# Output: output/zu11eg-dtb/system.dtb -> copy it over the one in the board's
# folder on the SD card's BOOT partition (keep the original).
set -euo pipefail

ADI_LINUX_REF="${ADI_LINUX_REF:-2023_R2}"     # matches ADI HDL 2023_R2_p1
DTS="${DTS:-zynqmp-adrv9009-zu11eg-revb-adrv2crr-fmc-revb-gps.dts}"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="${OUT:-$HERE/../../../output/zu11eg-dtb}"
SRC="$OUT/adi-linux"
mkdir -p "$OUT"

if [ ! -d "$SRC/.git" ]; then
    git clone --quiet --depth 1 --filter=blob:none --sparse \
        --branch "$ADI_LINUX_REF" https://github.com/analogdevicesinc/linux.git "$SRC"
    git -C "$SRC" sparse-checkout set --no-cone '/arch/arm64/boot/dts/xilinx/' \
        '/include/dt-bindings/' '/include/uapi/linux/input-event-codes.h'
fi
# dt-bindings/input/linux-event-codes.h is a symlink into uapi; on a Windows
# bind mount it can arrive as a plain text file, so materialise it.
EV="$SRC/include/dt-bindings/input/linux-event-codes.h"
if ! grep -q 'define KEY_RESERVED' "$EV" 2>/dev/null; then
    rm -f "$EV"
    cp "$SRC/include/uapi/linux/input-event-codes.h" "$EV"
fi

cp "$HERE/$DTS" "$SRC/arch/arm64/boot/dts/xilinx/"
PRE="$OUT/${DTS%.dts}.pre.dts"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "$SRC/include" -I "$SRC/arch/arm64/boot/dts/xilinx" \
    "$SRC/arch/arm64/boot/dts/xilinx/$DTS" -o "$PRE"
dtc -q -@ -I dts -O dtb -o "$OUT/system.dtb" "$PRE"

# Prove the additions made it into the blob.
dtc -q -I dtb -O dts "$OUT/system.dtb" > "$OUT/system.check.dts"
grep -q 'compatible = "pps-gpio"' "$OUT/system.check.dts"
grep -q 'pps-counter@9c460000' "$OUT/system.check.dts"
echo "system.dtb ($ADI_LINUX_REF + GPS) -> $OUT/system.dtb"
