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

# LibreSDR Rev.5 boards seen in the field use a Winbond W25Q256JV 256-Mbit
# QSPI NOR. The Zynq-7000 QSPI controller driver in this ADI/Xilinx kernel only
# supports 3-byte address phases, so Linux relies on the SPI-NOR core's
# Extended Address Register (EAR) path above 16 MiB. The inherited Xilinx EAR
# helpers know AMD/Micron/Macronix/PMC, but not Winbond. The symptom is:
#
#   spi-nor spi1.0: failed to read ear reg
#
# and writes that cross the 16 MiB boundary can wrap/corrupt lower flash
# addresses. Winbond uses RDEAR=0xc8 and WREAR=0xc5, the same opcodes already
# named SPINOR_OP_RDEAR/SPINOR_OP_WREAR here; add manufacturer 0xef to this
# legacy helper path and require write-enable before WREAR.
python3 - <<'PY'
from pathlib import Path

path = Path("linux/drivers/mtd/spi-nor/core.c")
text = path.read_text()
old_write = """\tif (nor->jedec_id == CFI_MFR_ST ||
\t    nor->jedec_id == CFI_MFR_MACRONIX ||
\t    nor->jedec_id == CFI_MFR_PMC) {
\t\tspi_nor_write_enable(nor);
\t\tcode = SPINOR_OP_WREAR;
\t}
"""
new_write = """\tif (nor->jedec_id == CFI_MFR_ST ||
\t    nor->jedec_id == CFI_MFR_MACRONIX ||
\t    nor->jedec_id == CFI_MFR_PMC ||
\t    nor->jedec_id == 0xef /* Winbond */) {
\t\tspi_nor_write_enable(nor);
\t\tcode = SPINOR_OP_WREAR;
\t}
"""
old_read = """\telse if (nor->jedec_id == CFI_MFR_ST ||
\t\t nor->jedec_id == CFI_MFR_MACRONIX ||
\t\t nor->jedec_id == CFI_MFR_PMC)
\t\tcode = SPINOR_OP_RDEAR;
"""
new_read = """\telse if (nor->jedec_id == CFI_MFR_ST ||
\t\t nor->jedec_id == CFI_MFR_MACRONIX ||
\t\t nor->jedec_id == CFI_MFR_PMC ||
\t\t nor->jedec_id == 0xef /* Winbond */)
\t\tcode = SPINOR_OP_RDEAR;
"""
for old, new, label in (
    (old_write, new_write, "Winbond WREAR"),
    (old_read, new_read, "Winbond RDEAR"),
):
    if old not in text:
        raise SystemExit(f"expected SPI-NOR EAR anchor missing: {label}")
    text = text.replace(old, new, 1)
path.write_text(text)
print("Patched Linux SPI-NOR EAR helpers for Winbond W25Q256 on Zynq QSPI")
PY

# LibreSDR Rev.5's DFU button is PS_MIO12, pulled up and active-low. The
# upstream Pluto environment checks GPIO14, which is not the LibreSDR button.
# On LibreSDR, MIO14/MIO15 are FTDI debug UART TX/RX, MIO11 is USB overcurrent,
# MIO9 is Ethernet PHY reset, and MIO10 is believed to be Ethernet PHY INT.
# Patch U-Boot's built-in default environment before building u-boot.elf; the
# staged uEnv.txt is checked and patched again below as a guard. The inherited
# Pluto dfu_sf also toggles GPIO15; remove that because GPIO15 is LibreSDR's
# FTDI debug UART pair. The preboot check is required because the qspiboot-only
# check is not evaluated on SD boot.
python3 - <<'PY'
from pathlib import Path

root = Path("u-boot-xlnx")
dfu_check = (
    "gpio input 12 && set stdout serial@e0000000 && sf probe && "
    "sf protect lock 0 100000 && run dfu_sf;"
)

gpio14_hits = 0
preboot_hits = 0
serial_hits = 0
gpio15_hits = 0
maxcpus_hits = 0
plutoreva_hits = 0
bootargs_hits = 0

def patch_preboot(text: str) -> tuple[str, int]:
    hits = 0
    out = []
    for line in text.splitlines(keepends=True):
        if (
            "preboot=" in line
            and "sd_uEnvtxt_existence_test" in line
            and dfu_check not in line
        ):
            line = line.replace("preboot=", f"preboot={dfu_check} ", 1)
            hits += 1
        out.append(line)
    return "".join(out), hits

for path in root.rglob("*"):
    if not path.is_file():
        continue
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue

    new = text
    if "gpio input 14" in new:
        gpio14_hits += 1
        new = new.replace("gpio input 14", "gpio input 12")
    if (
        "serial@e0001000" in new
        and any(marker in new for marker in ("dfu_sf=", "qspiboot=", "preboot="))
    ):
        serial_hits += 1
        new = new.replace("serial@e0001000", "serial@e0000000")
    if "dfu_sf=" in new and ("gpio set 15;" in new or ";gpio clear 15" in new):
        gpio15_hits += 1
        new = new.replace("dfu_sf=gpio set 15;", "dfu_sf=")
        new = new.replace(";gpio clear 15", "")
    if "maxcpus=1" in new and any(marker in new for marker in ("qspiboot=", "maxcpus=")):
        maxcpus_hits += 1
        new = new.replace("maxcpus=1", "maxcpus=2")
    if "test -n $PlutoRevA || gpio input 12" in new:
        plutoreva_hits += 1
        new = new.replace("test -n $PlutoRevA || gpio input 12", "gpio input 12")
    if (
        "setenv bootargs console=ttyPS0,115200" in new
        and "cpuidle.off=1" not in new
    ):
        bootargs_hits += 1
        new = new.replace(
            'clk_ignore_unused uboot="${uboot-version}"',
            'clk_ignore_unused cpuidle.off=1 '
            'uio_pdrv_genirq.of_id=uio_pdrv_genirq uboot="${uboot-version}"',
        )
    new, hits = patch_preboot(new)
    preboot_hits += hits

    if new != text:
        path.write_text(new)

if gpio14_hits == 0:
    raise SystemExit("expected Pluto DFU GPIO14 check is missing from U-Boot sources")
if preboot_hits == 0:
    raise SystemExit("expected U-Boot preboot environment was not patched")
print(
    f"Patched LibreSDR U-Boot DFU env: gpio14 files={gpio14_hits}, "
    f"preboot files={preboot_hits}, serial files={serial_hits}, "
    f"gpio15 files={gpio15_hits}, maxcpus files={maxcpus_hits}, "
    f"PlutoRevA files={plutoreva_hits}, bootargs files={bootargs_hits}"
)
PY

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
# Fail-fast anti-truncation guard: a real LibreSDR (XC7Z020) bitstream is ~2.4 MB. A
# ~241 KB .bit is the fingerprint of an fdt-pip-lib-truncated extract and WILL brick the
# board (cf. Pluto+ v1.5/v2.0.1). Refuse it rather than package a doomed FIT.
_bitsz=$(stat -c %s "$PREBUILT_BIT")
if [ "$_bitsz" -lt 400000 ]; then
    die "PREBUILT_BIT is only ${_bitsz} bytes -- almost certainly a TRUNCATED bitstream (real is ~2.4 MB). Re-export from Vivado or extract with dumpimage/mkimage (NEVER the fdt pip lib). See RELEASING.md."
fi

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

# Legacy U-Boot's `gpio input` returns the pin value as the shell status, so a
# low/pressed active-low button makes `gpio input 12 && ...` take the DFU path.
sed -i 's/gpio input 14/gpio input 12/g; s/serial@e0001000/serial@e0000000/g' \
    build/uboot-env.txt
sed -i 's/dfu_sf=gpio set 15;/dfu_sf=/g; s/;gpio clear 15//g' \
    build/uboot-env.txt
sed -i 's/^maxcpus=1$/maxcpus=2/' build/uboot-env.txt
sed -i 's/test -n \$PlutoRevA || gpio input 12/gpio input 12/g' \
    build/uboot-env.txt
python3 - <<'PY'
from pathlib import Path

path = Path("build/uboot-env.txt")
text = path.read_text()
dfu_check = (
    "gpio input 12 && set stdout serial@e0000000 && sf probe && "
    "sf protect lock 0 100000 && run dfu_sf;"
)
lines = []
for line in text.splitlines(keepends=True):
    if (
        line.startswith("preboot=")
        and "sd_uEnvtxt_existence_test" in line
        and dfu_check not in line
    ):
        line = line.replace("preboot=", f"preboot={dfu_check} ", 1)
    if line.startswith(("qspiboot=", "qspiboot_verbose=", "ramboot_verbose=")):
        line = line.replace(
            'clk_ignore_unused uboot="${uboot-version}"',
            'clk_ignore_unused cpuidle.off=1 '
            'uio_pdrv_genirq.of_id=uio_pdrv_genirq uboot="${uboot-version}"',
        )
    lines.append(line)
text = "".join(lines)
path.write_text(text)
PY
grep -Fq 'gpio input 12 && set stdout' build/uboot-env.txt ||
    die "LibreSDR DFU button GPIO patch is missing from build/uboot-env.txt"
if grep -Fq 'gpio input 14 && set stdout' build/uboot-env.txt; then
    die "Pluto GPIO14 DFU button check leaked into build/uboot-env.txt"
fi
grep -Fq 'preboot=' build/uboot-env.txt &&
    grep -Fq 'gpio input 12 && set stdout serial@e0000000' build/uboot-env.txt ||
    die "LibreSDR DFU button preboot check is missing from build/uboot-env.txt"
if grep -Fq 'serial@e0001000' build/uboot-env.txt; then
    die "Pluto UART1 console leaked into LibreSDR U-Boot environment"
fi
if grep -Eq 'gpio (set|clear) 15' build/uboot-env.txt; then
    die "Pluto GPIO15 DFU indicator leaked into LibreSDR U-Boot environment"
fi
if grep -Fq 'PlutoRevA' build/uboot-env.txt; then
    die "PlutoRevA conditional leaked into LibreSDR U-Boot environment"
fi
grep -Fxq 'maxcpus=2' build/uboot-env.txt ||
    die "LibreSDR U-Boot environment must keep both Zynq-7020 CPUs online"
if grep -Fxq 'maxcpus=1' build/uboot-env.txt; then
    die "Pluto single-CPU maxcpus setting leaked into LibreSDR U-Boot environment"
fi
grep -Fq 'cpuidle.off=1' build/uboot-env.txt ||
    die "LibreSDR U-Boot bootargs dropped cpuidle.off=1 from the known-good env"
grep -Fq 'uio_pdrv_genirq.of_id=uio_pdrv_genirq' build/uboot-env.txt ||
    die "LibreSDR U-Boot bootargs dropped the known-good UIO platform-driver binding"

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

# Fail-hard anti-brick gate: never let a build succeed with a truncated bitstream (the
# Pluto+ v1.5/v2.0.1 brick). Re-measure the produced FIT with the shared release check
# (mkimage-based; never the fdt pip lib); quarantine + fail if any image is short.
if [ -f "$OUT/libre.frm" ] && [ -f /build/test-src/check_frm_images.sh ]; then
    info "Anti-truncation gate: validating libre.frm image sizes (mkimage)..."
    if ! sh /build/test-src/check_frm_images.sh "$OUT/libre.frm"; then
        mv "$OUT/libre.frm" "$OUT/libre.frm.TRUNCATED-DO-NOT-FLASH" 2>/dev/null || true
        die "libre.frm FAILED the image-integrity gate (truncated bitstream?). Quarantined as libre.frm.TRUNCATED-DO-NOT-FLASH. Refusing to ship a brick."
    fi
    info "  anti-truncation gate: PASS"
fi

sh /build/boards-src/libresdr/validate_sd.sh "$SD"

info "Linux build complete."
info "Finalize SD BOOT.bin on Windows:"
info "  powershell -File tools/finalize-libresdr-sd.ps1"
