#!/usr/bin/env bash
# Build BOOT.BIN for the ADRV9009-ZU11EG + ADRV2CRR-FMC from the new design.
#
#   bash boards/adrv9009zu11eg/make_boot_bin.sh <system_top.xsa> [bootgen_sysfiles.tgz]
#
# system_top.xsa   build_hdl.py output (gps-timing-out/), i.e. after a licensed
#                  synthesis + implementation.
# bootgen_sysfiles.tgz
#                  from the board's folder on the ADI Kuiper SD card's BOOT
#                  partition; it holds the u-boot.elf and bl31.elf ADI built for
#                  this board and release. Without it, ADI's script downloads the
#                  board's u-boot.elf and builds bl31.elf from source
#                  (needs aarch64-linux-gnu-gcc).
#
# Runs ADI's build_zynqmp_boot_bin.sh at a pinned commit, which builds the FSBL
# and PMU firmware from the .xsa with xsct and packs everything with bootgen.
# Needs a Linux shell with Vivado + Vitis 2023.2 sourced (xsct, bootgen, vitis
# on PATH). Output: output/zu11eg-boot/BOOT.BIN.
set -euo pipefail

XSA=$(realpath "${1:?usage: $0 system_top.xsa [bootgen_sysfiles.tgz]}")
SYSFILES=${2:-}
ADI_SCRIPTS_COMMIT=2beb4b9ec109a4521600fdadfe2797e5294a3571
SCRIPT_URL="https://raw.githubusercontent.com/analogdevicesinc/wiki-scripts/$ADI_SCRIPTS_COMMIT/zynqmp_boot_bin/build_zynqmp_boot_bin.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "${OUT:-$HERE/../../output/zu11eg-boot}")

rm -rf "$OUT" && mkdir -p "$OUT" && cd "$OUT"
curl -fsSL "$SCRIPT_URL" -o build_zynqmp_boot_bin.sh

UBOOT=download
ATF=download
if [ -n "$SYSFILES" ]; then
    mkdir sysfiles
    tar -xzf "$(realpath "$SYSFILES")" -C sysfiles
    UBOOT=$(find sysfiles -name 'u-boot*.elf' | head -n1)
    ATF=$(find sysfiles -name 'bl31.elf' | head -n1)
    [ -n "$UBOOT" ] && [ -n "$ATF" ] || { echo "u-boot.elf / bl31.elf not in $SYSFILES" >&2; exit 1; }
fi

bash build_zynqmp_boot_bin.sh "$XSA" "$UBOOT" "$ATF"
cp output_boot_bin/BOOT.BIN "$OUT/BOOT.BIN"
echo "BOOT.BIN -> $OUT/BOOT.BIN (copy it over the one in the board's folder on the SD card; keep the original)"
