#!/usr/bin/env bash
# Build system.dtb for ADRV9009-ZU11EG + ADRV2CRR-FMC with the GPS additions.
#
#   BASE=<kuiper folder name> bash boards/adrv9009zu11eg/dts/build_dtb.sh
#
# BASE is the name of the Kuiper BOOT-partition folder you boot from (it is
# also the name of ADI's .dts); default zynqmp-adrv9009-zu11eg-revb-adrv2crr-fmc-revb.
# Needs git, cpp and dtc; the repo's builder image has all three:
#
#   docker run --rm -v "$PWD":/w -w /w -e BASE=... plutoplus-gps-builder \
#       bash boards/adrv9009zu11eg/dts/build_dtb.sh
#
# Output: output/zu11eg-dtb/system.dtb
set -euo pipefail

ADI_LINUX_REF="${ADI_LINUX_REF:-2023_R2}"     # matches ADI HDL 2023_R2_p1
BASE="${BASE:-zynqmp-adrv9009-zu11eg-revb-adrv2crr-fmc-revb}"
BASE="${BASE%.dts}"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="${OUT:-$HERE/../../../output/zu11eg-dtb}"
SRC="$OUT/adi-linux"
DTSDIR="$SRC/arch/arm64/boot/dts/xilinx"
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

[ -f "$DTSDIR/$BASE.dts" ] || {
    echo "no $BASE.dts in ADI Linux $ADI_LINUX_REF; valid BASE values:" >&2
    for f in "$DTSDIR"/zynqmp-adrv9009-zu11eg-*adrv2crr*.dts; do
        case $f in *-gps.dts) ;; *) basename "$f" .dts ;; esac
    done >&2
    exit 1
}
cp "$HERE/gps.dtsi" "$DTSDIR/plutoplus-gps.dtsi"
printf '#include "%s.dts"\n#include "plutoplus-gps.dtsi"\n' "$BASE" > "$DTSDIR/$BASE-gps.dts"

PRE="$OUT/$BASE-gps.pre.dts"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "$SRC/include" -I "$DTSDIR" "$DTSDIR/$BASE-gps.dts" -o "$PRE"
dtc -q -@ -I dts -O dtb -o "$OUT/system.dtb" "$PRE"

# Prove the additions made it into the blob.
dtc -q -I dtb -O dts "$OUT/system.dtb" > "$OUT/system.check.dts"
grep -q 'compatible = "pps-gpio"' "$OUT/system.check.dts"
grep -q 'pps-counter@9c460000' "$OUT/system.check.dts"
echo "system.dtb ($BASE, ADI Linux $ADI_LINUX_REF, + GPS) -> $OUT/system.dtb"
