#!/bin/sh
# check_frm_images.sh - release-artifact gate: prove a built .frm's FIT images are
# FULL-SIZE, not truncated. This catches the exact class of brick we shipped twice:
#   v1.5   -- 241 KB fpga@1 (real 965 KB): PL can't configure -> boot hang -> brick
#   v2.0.1 -- 241 KB fpga@1 again, from a --prebuilt-bit build fed an fdt-truncated .bit
#
# The truncation is invisible to md5-of-frm, FIT-structure checks, and the `fdt` Python
# lib (which ITSELF silently truncates large `data` props -- never use it to measure).
# We use u-boot's own `mkimage -l` (or `dumpimage -l`), which reports true Data Sizes.
#
# Usage:
#   sh test/check_frm_images.sh output/pluto.frm                 # absolute-floor check
#   sh test/check_frm_images.sh output/pluto.frm prev.frm        # + shrink-vs-reference
#
# Exit 0 = all images full-size and trailer valid; non-zero = STOP, do not release.
set -u

FRM="${1:?usage: check_frm_images.sh <new.frm> [reference.frm]}"
REF="${2:-}"

# Absolute floors (bytes). A correct build is far above these; a truncated fdt-extract
# (~241 KB) falls below the fpga floor. Kernel/ramdisk floors are loose sanity checks.
FPGA_MIN=400000
KERNEL_MIN=1000000
RAMDISK_MIN=1000000
SHRINK_PCT=90        # if a reference is given, each image must be >= 90% of its size

have() { command -v "$1" >/dev/null 2>&1; }
LISTER=""
if have mkimage; then LISTER="mkimage -l"
elif have dumpimage; then LISTER="dumpimage -l"
else
    echo "FAIL: need u-boot-tools (mkimage/dumpimage) to measure FIT images."
    echo "      apt-get install u-boot-tools   (do NOT fall back to the fdt pip lib -- it truncates)"
    exit 2
fi

rc=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# .frm = FIT.itb + 33-byte md5 trailer. Strip the trailer to get a clean .itb, and
# verify the trailer md5 == md5(FIT.itb) -- the same check update_frm.sh makes.
strip_and_check() {
    _frm="$1"; _itb="$2"
    _sz=$(wc -c < "$_frm")
    head -c "$((_sz - 33))" "$_frm" > "$_itb"
    _trailer=$(tail -c 33 "$_frm" | tr -d '\n\r ')
    _calc=$(md5sum "$_itb" | cut -d' ' -f1)
    [ "$_trailer" = "$_calc" ]
}

# echo "<name> <data_size>" per image from the FIT listing.
image_sizes() {
    $LISTER "$1" 2>/dev/null | awk '
        /Image[ ]+[0-9]+ \(/ { name=$0; sub(/.*\(/,"",name); sub(/\).*/,"",name); next }
        /Data Size:/ { for(i=1;i<=NF;i++) if($i=="Bytes"){ print name, $(i-1) } }'
}

size_of() { echo "$1" | awk -v n="$2" '$1==n {print $2; found=1} END{if(!found) print -1}'; }

echo "=== check_frm_images: $FRM ==="
if ! strip_and_check "$FRM" "$tmp/new.itb"; then
    echo "FAIL: $FRM md5 trailer does not match its FIT.itb -- malformed .frm (update_frm.sh would reject)"
    rc=1
fi
NEW=$(image_sizes "$tmp/new.itb")
[ -n "$NEW" ] || { echo "FAIL: could not read any FIT images from $FRM"; exit 1; }

check_floor() {
    _name="$1"; _min="$2"
    _s=$(size_of "$NEW" "$_name")
    if [ "$_s" -lt 0 ] 2>/dev/null; then echo "FAIL: image '$_name' not found in FIT"; rc=1; return; fi
    if [ "$_s" -lt "$_min" ]; then
        echo "FAIL: $_name = $_s B  < floor $_min B  -- TRUNCATED? (this is the v1.5/v2.0.1 brick)"; rc=1
    else
        echo "  ok: $_name = $_s B  (>= $_min)"
    fi
}
check_floor "fpga@1"        "$FPGA_MIN"
check_floor "linux_kernel@1" "$KERNEL_MIN"
check_floor "ramdisk@1"      "$RAMDISK_MIN"

# fit_size u-boot must be set to (bootability invariant; see FLASHING.md)
ITB_SZ=$(wc -c < "$tmp/new.itb")
printf '  fit_size to set: 0x%X (%d bytes) -- update_frm.sh sets this; verify with fw_printenv\n' "$ITB_SZ" "$ITB_SZ"

# Optional shrink-vs-reference: catches ANY image that lost bytes vs a known-good frm.
if [ -n "$REF" ]; then
    echo "--- vs reference $REF ---"
    if strip_and_check "$REF" "$tmp/ref.itb"; then
        REFS=$(image_sizes "$tmp/ref.itb")
        for name in "fpga@1" "linux_kernel@1" "ramdisk@1"; do
            n=$(size_of "$NEW" "$name"); r=$(size_of "$REFS" "$name")
            [ "$r" -gt 0 ] 2>/dev/null || continue
            pct=$(( n * 100 / r ))
            if [ "$pct" -lt "$SHRINK_PCT" ]; then
                echo "FAIL: $name shrank to ${pct}% of reference ($n vs $r) -- investigate before release"; rc=1
            else
                echo "  ok: $name ${pct}% of reference ($n vs $r)"
            fi
        done
    else
        echo "  (reference $REF trailer invalid -- skipping shrink check)"
    fi
fi

echo
[ "$rc" -eq 0 ] && echo "=== check_frm_images: PASS ===" || echo "=== check_frm_images: FAIL (do NOT release) ==="
exit $rc
