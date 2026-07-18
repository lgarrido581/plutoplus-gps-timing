#!/bin/sh
# check_frm_images.sh - release-artifact gate: prove a built .frm's FIT images are
# FULL-SIZE, not truncated. This catches the exact class of brick we shipped twice:
#   v1.5   -- 241 KB fpga@1 (real 965 KB): PL can't configure -> boot hang -> brick
#   v2.0.1 -- 241 KB fpga@1 again, from a --prebuilt-bit build fed an fdt-truncated .bit
#
# The truncation is invisible to md5-of-frm and FIT-structure sanity checks. We measure
# each /images/* embedded `data` property's TRUE length by parsing the FIT's flattened
# device tree directly (the FDT_PROP length field is authoritative). We deliberately do
# NOT use:
#   * the `fdt` PYTHON pip lib -- it silently truncates large `data` props, and
#   * `mkimage -l` / `dumpimage -l` -- u-boot-tools 2022.01 misdetects a bare FIT as a
#     "GP Header" (the gpimage type check matches any file first) and lists no images,
#     which false-quarantined every real build. See git history for the switch.
#
# Usage:
#   sh test/check_frm_images.sh output/pluto.frm                 # absolute-floor check
#   sh test/check_frm_images.sh output/pluto.frm prev.frm        # + shrink-vs-reference
#
# Requires: python3 (stdlib only) + coreutils. Exit 0 = all images full-size and trailer
# valid; non-zero = STOP, do not release.
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
if ! have python3; then
    echo "FAIL: need python3 (stdlib) to measure FIT images."
    echo "      apt-get install python3   (do NOT fall back to mkimage -l -- it misdetects FITs)"
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

# echo "<name> <data_size>" per /images/* node, reading the FDT_PROP length of each
# image's embedded `data` property straight from the flattened device tree. Version-
# independent and exact (no mkimage, no fdt pip lib). Warns to stderr if totalsize!=body.
image_sizes() {
    python3 - "$1" <<'PY'
import sys, struct
b = open(sys.argv[1], "rb").read()
if len(b) < 16 or b[:4] != b"\xd0\x0d\xfe\xed":
    sys.exit(0)  # not a FIT -> emit nothing -> caller reports "could not read"
totalsize, off_struct, off_strings = struct.unpack(">III", b[4:16])
if totalsize != len(b) or off_strings > len(b) or off_struct > len(b):
    # inconsistent header = truncated/corrupt: emit nothing so the caller FAILs cleanly.
    sys.stderr.write("WARN: FIT header inconsistent (totalsize %d, body %d) -- truncated?\n"
                     % (totalsize, len(b)))
    sys.exit(0)
align4 = lambda x: (x + 3) & ~3
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9
pos, stack = off_struct, []
try:
    while pos < off_strings:
        (tag,) = struct.unpack(">I", b[pos:pos+4]); pos += 4
        if tag == FDT_BEGIN_NODE:
            e = b.index(b"\x00", pos); stack.append(b[pos:e].decode("ascii", "replace"))
            pos = align4(e + 1)
        elif tag == FDT_END_NODE:
            stack.pop()
        elif tag == FDT_PROP:
            length, nameoff = struct.unpack(">II", b[pos:pos+8]); pos += 8
            e = b.index(b"\x00", off_strings + nameoff)
            pname = b[off_strings + nameoff:e].decode("ascii", "replace")
            segs = [s for s in stack if s]
            if pname == "data" and len(segs) == 2 and segs[0] == "images":
                print(segs[1], length)
            pos = align4(pos + length)
        elif tag == FDT_NOP:
            continue
        elif tag == FDT_END:
            break
        else:
            break
except (struct.error, ValueError, IndexError):
    sys.stderr.write("WARN: FIT struct walk aborted -- malformed/truncated\n")
PY
}

size_of() { echo "$1" | awk -v n="$2" '$1==n {print $2; found=1} END{if(!found) print -1}'; }

# sha256 of the fpga@1 image's embedded `data` (the actual bitstream bytes). Same FDT walk
# as image_sizes, but hashes the one image whose identity matters: a wrong bitstream (e.g.
# a plain ./docker-run.sh that pulled the stock bit instead of the coincident-capture one)
# is byte-valid and full-size, so the floor check passes -- only the hash catches it.
fpga_sha256() {
    python3 - "$1" <<'PY'
import sys, struct, hashlib
b = open(sys.argv[1], "rb").read()
if len(b) < 16 or b[:4] != b"\xd0\x0d\xfe\xed": sys.exit(0)
totalsize, off_struct, off_strings = struct.unpack(">III", b[4:16])
align4 = lambda x: (x + 3) & ~3
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9
pos, stack = off_struct, []
try:
    while pos < off_strings:
        (tag,) = struct.unpack(">I", b[pos:pos+4]); pos += 4
        if tag == FDT_BEGIN_NODE:
            e = b.index(b"\x00", pos); stack.append(b[pos:e].decode("ascii", "replace")); pos = align4(e + 1)
        elif tag == FDT_END_NODE: stack.pop()
        elif tag == FDT_PROP:
            length, nameoff = struct.unpack(">II", b[pos:pos+8]); pos += 8
            e = b.index(b"\x00", off_strings + nameoff)
            pname = b[off_strings + nameoff:e].decode("ascii", "replace")
            segs = [s for s in stack if s]
            if pname == "data" and len(segs) == 2 and segs[0] == "images" and segs[1] == "fpga@1":
                print(hashlib.sha256(b[pos:pos+length]).hexdigest()); sys.exit(0)
            pos = align4(pos + length)
        elif tag == FDT_NOP: continue
        elif tag == FDT_END: break
        else: break
except (struct.error, ValueError, IndexError): pass
PY
}

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

# fpga@1 bitstream identity -- printed always (visible in every build/release log), and if a
# known-good hash is pinned via $EXPECTED_FPGA_SHA256, FAIL on mismatch. A full-size-but-WRONG
# bitstream (e.g. the stock bit pulled by a bare ./docker-run.sh, lacking the coincident-capture
# pps_counter) passes every OTHER check here; the hash is the only gate that catches it.
FPGA_SHA=$(fpga_sha256 "$tmp/new.itb")
if [ -n "$FPGA_SHA" ]; then
    echo "  fpga@1 sha256 = $FPGA_SHA"
    if [ -n "${EXPECTED_FPGA_SHA256:-}" ]; then
        if [ "$FPGA_SHA" = "$EXPECTED_FPGA_SHA256" ]; then
            echo "  ok: fpga@1 matches the pinned known-good bitstream"
        else
            echo "FAIL: fpga@1 sha256 != pinned known-good ($EXPECTED_FPGA_SHA256)"
            echo "      NOT the validated bitstream -- it likely LACKS the coincident-capture pps_counter"
            echo "      (radio boots pps=N / GPS-untrusted). Rebuild reusing the known-good bit"
            echo "      (--prebuilt-bit output/working.bit); update the pin ONLY if you changed gateware."
            rc=1
        fi
    fi
else
    echo "  (fpga@1 sha256: could not extract -- FIT missing fpga@1?)"
fi

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
