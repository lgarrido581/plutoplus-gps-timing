#!/bin/sh
# Fail the LibreSDR build before deployment if staged SD artifacts disagree
# with the runtime assumptions exercised during hardware bring-up.
set -eu

SD="${1:?usage: validate_sd.sh <staged-sd-directory>}"

fail() {
    echo "[ERR] LibreSDR artifact validation: $*" >&2
    exit 1
}

for name in boot.bif fsbl.elf system_top.bit u-boot.elf uImage \
            devicetree.dtb uEnv.txt ramdisk.image.gz uramdisk.image.gz; do
    [ -s "$SD/$name" ] || fail "missing or empty $name"
done

gzip -t "$SD/ramdisk.image.gz" || fail "ramdisk gzip integrity check failed"
mkimage -l "$SD/uImage" >/dev/null || fail "invalid kernel uImage"
mkimage -l "$SD/uramdisk.image.gz" >/dev/null || fail "invalid ramdisk uImage"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(
    cd "$TMP"
    gzip -dc "$SD/ramdisk.image.gz" |
        cpio -id --quiet 'etc' 'etc/*' 'usr' 'usr/bin' \
            'usr/bin/xo_correct.sh' 'usr/bin/verify_lvds.sh'
)

ROOT="$TMP"
grep -Fq 'BOARD=libresdr' "$ROOT/etc/gps-timing-board" ||
    fail "board identity missing"
grep -Fq 'GPS_UART=/dev/ttyUL0' "$ROOT/etc/gps-timing-board" ||
    fail "LibreSDR UART identity missing"
grep -Fq 'ttyGS0::respawn:' "$ROOT/etc/inittab" ||
    fail "USB serial login console missing"
grep -Fq 'ttyPS0::respawn:' "$ROOT/etc/inittab" ||
    fail "physical debug login console missing"
grep -Fq 'echo "end $IPADDR_HOST" >> $UDHCPD_CONF' "$ROOT/etc/init.d/S40network" ||
    fail "valid udhcpd end address is not generated"
grep -Fq '# Deferred to S46udc-bind on LibreSDR' "$ROOT/etc/init.d/S23udc" ||
    fail "early incomplete USB gadget bind is still enabled"
grep -Fq 'echo ci_hdrc.0 > "$G/UDC"' "$ROOT/etc/init.d/S46udc-bind" ||
    fail "post-MSD USB gadget bind is missing"
if grep -Fq '/etc/init.d/S41network restart' "$ROOT/etc/init.d/S46udc-bind"; then
    fail "USB gadget bind still cycles the RNDIS network"
fi
grep -Fq 'DEVICES="/dev/ttyUL0"' "$ROOT/etc/init.d/S50gpsd" ||
    fail "gpsd is not configured for ttyUL0"
grep -Fq 'refclock PPS /dev/pps0' "$ROOT/etc/chrony.conf" ||
    fail "chrony PPS source missing"
[ -x "$ROOT/usr/bin/verify_lvds.sh" ] ||
    fail "LibreSDR LVDS hardware acceptance test missing"
grep -Fq 'bist_timing_analysis' "$ROOT/usr/bin/verify_lvds.sh" ||
    fail "LibreSDR LVDS test does not run PRBS timing analysis"

dtc -q -I dtb -O dts "$SD/devicetree.dtb" > "$TMP/devicetree.dts" ||
    fail "device tree cannot be decompiled"
grep -Fq 'serial@40600000' "$TMP/devicetree.dts" ||
    fail "UART Lite DT node missing"
grep -Fq 'tdd@7c440000' "$TMP/devicetree.dts" ||
    fail "AXI TDD DT node missing"
grep -Fq 'compatible = "adi,axi-tdd";' "$TMP/devicetree.dts" ||
    fail "AXI TDD v2 binding missing"
grep -Fq 'pps-counter@7c460000' "$TMP/devicetree.dts" ||
    fail "PPS counter DT node missing"
grep -Fq 'pps-gpio' "$TMP/devicetree.dts" ||
    fail "Linux PPS GPIO node missing"

echo "[INFO] LibreSDR staged SD artifacts passed offline validation"
