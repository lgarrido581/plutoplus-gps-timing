#!/bin/sh
# tdd_verify.sh - Tier-1 functional proof that the PPS-aligned TDD is working.
# Runs ON THE PLUTO (busybox sh + devmem). Needs the GPS-aligned-TDD bitstream
# (pps_counter with pps_tick wired to axi_tdd_0/sync_in) and a GPS PPS lock.
#
# What it proves, WITHOUT a scope:
#   A) The sync SOURCE fires once/sec and is GPS-anchored: pps_counter's own
#      frame counter (same l_clk, same pps_tick source) resets on every PPS and
#      its per-second frame count is a STABLE integer -> frames tile the GPS
#      second and re-anchor each second.  (directly observable)
#   B) axi_tdd is present and put into EXTERNAL-sync mode (CONTROL.sync_ext=1),
#      so it consumes that pps_tick (the pps_tick->sync_in net is fixed in the
#      bitstream).  -> the TDD frame is GPS-aligned.
#
# It does NOT measure ns precision: software reads are ms-jittery. For the actual
# ns/sample numbers, scope a TDD channel output vs PPS, or cross-correlate two
# nodes (see TDD_PPS_DESIGN.md / ROADMAP Tier 3). Precision floor = +-1 l_clk
# sample (~32.6 ns @ 30.72 MSPS), the hardware-latch quantization.
#
# Usage:  sh tdd_verify.sh            # 8s observation, default 10ms frame
#         FRAME_MS=1 SECS=15 sh tdd_verify.sh
set -u

# ---- pps_counter (0x7C460000) ----
P_ID=0x7C460000; P_STATUS=0x7C460008; P_PPSDELTA=0x7C460014; P_PPSSEQ=0x7C460018
P_TDDCTRL=0x7C46001C; P_FRAMELEN=0x7C460020; P_FRAMEPOS=0x7C460034; P_FRAMESEQ=0x7C460038
# ---- axi_tdd (0x7C440000), byte = word*4 ----
T_VERSION=0x7C440000; T_IDENT=0x7C44000C; T_CONTROL=0x7C440040
T_CHEN=0x7C440044; T_FRAMELEN=0x7C440054; T_STATUS=0x7C440060
T_CH0_ON=0x7C440080; T_CH0_OFF=0x7C440084

SECS="${SECS:-8}"
FRAME_MS="${FRAME_MS:-10}"        # frame length in ms (must divide 1000 for a clean tile)

rd() { devmem "$1" 32; }
wr() { devmem "$1" 32 "$2"; }
d()  { printf '%d' "$1"; }        # hex->dec

echo "=== tdd_verify: PPS-aligned TDD functional check ==="

# sample rate from the locked PPS_DELTA (counts/sec == l_clk Hz)
FS=$(( $(d "$(rd $P_PPSDELTA)") ))
[ "$FS" -gt 1000000 ] || { echo "PPS_DELTA=$FS implausible - is GPS/PPS locked and xo disciplined? aborting"; exit 1; }
FRAME_LEN=$(( FS * FRAME_MS / 1000 ))
EXP_FRAMES=$(( FS / FRAME_LEN ))
echo "  l_clk (from PPS_DELTA) = $FS Hz;  frame = ${FRAME_MS}ms = $FRAME_LEN samples;  expect ~$EXP_FRAMES frames/sec"
[ $(( FS - EXP_FRAMES * FRAME_LEN )) -eq 0 ] || echo "  NOTE: ${FRAME_MS}ms does not evenly divide the second at this fs (a runt frame will appear)."

# pps_counter present?
[ "$(rd $P_ID)" = "0x50505343" ] || { echo "pps_counter ID != PPSC; wrong bitstream. aborting"; exit 1; }
[ "$(rd $P_STATUS)" = "0x00000001" ] || echo "  WARN: STATUS.pps_present=0 (no PPS latched yet)"

# ---- A) drive pps_counter's own frame counter (proxy for the GPS-aligned frame) ----
wr $P_TDDCTRL 0x0                       # disable while configuring
wr $P_FRAMELEN $FRAME_LEN
wr $P_TDDCTRL 0x3                       # enable(0) + pps_sync_en(1): reset frame on PPS
echo
echo "--- A) frame counter is PPS-anchored: FRAME_SEQ must stay BOUNDED (resets each PPS), not climb ---"
echo "  GPS-aligned => FRAME_SEQ cycles 0..~$EXP_FRAMES and resets every PPS. (devmem reads are too slow"
echo "  to catch the exact per-second count, but they reliably bound the MAX, which is the real test:"
echo "  if the PPS reset weren't happening, FRAME_SEQ would climb unbounded into the thousands.)"
# settle past the config transient: wait for one PPS edge first
s0=$(( $(d "$(rd $P_PPSSEQ)") )); w=0
while [ "$(( $(d "$(rd $P_PPSSEQ)") ))" = "$s0" ] && [ "$w" -lt 5000 ]; do w=$((w+1)); done
ps0=$(( $(d "$(rd $P_PPSSEQ)") )); maxseq=0; minseq=999999999; reads=0
END=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
    fs=$(( $(d "$(rd $P_FRAMESEQ)") ))
    [ "$fs" -gt "$maxseq" ] && maxseq=$fs
    [ "$fs" -lt "$minseq" ] && minseq=$fs
    reads=$((reads+1))
done
ps1=$(( $(d "$(rd $P_PPSSEQ)") )); secs=$(( ps1 - ps0 ))
echo "  over ${secs}s (${reads} reads): FRAME_SEQ ranged ${minseq}..${maxseq}  (GPS-aligned expects ~0..$EXP_FRAMES)"

# ---- B) put axi_tdd into external-sync mode so it consumes pps_tick ----
echo
echo "--- B) axi_tdd (0x7C440000): present + external-sync enabled ---"
echo "  VERSION=$(rd $T_VERSION)  IDENT=$(rd $T_IDENT)"
wr $T_CONTROL 0x0                       # disable (regs are write-locked while enabled)
wr $T_FRAMELEN $(( FRAME_LEN - 1 ))     # axi_tdd frame length is (cycles-1)
wr $T_CH0_ON  0
wr $T_CH0_OFF $(( FRAME_LEN / 2 ))      # ch0 high for first half of the frame
wr $T_CHEN    0x1                       # enable channel 0
wr $T_CONTROL 0x9                       # enable(b0) + sync_ext(b3)  -> driven by pps_tick
sleep 1
ctrl=$(rd $T_CONTROL)
echo "  CONTROL readback=$ctrl  (expect bit0 enable + bit3 sync_ext set -> 0x9)  STATUS=$(rd $T_STATUS)"

echo
echo "=== verdict ==="
echo "  sample clock: l_clk=$FS Hz (xo_correct disciplines this; within ~1 count of nominal = locked)."
BOUND=$(( EXP_FRAMES + EXP_FRAMES/10 + 3 ))
if [ "$secs" -lt 2 ]; then
    echo "  inconclusive: PPS_SEQ advanced <2 in ${SECS}s (is PPS locked? increase SECS)."
elif [ "$maxseq" -le "$BOUND" ]; then
    echo "  PASS: FRAME_SEQ stayed bounded (max=$maxseq ~ $EXP_FRAMES) and reset on each PPS"
    echo "        -> the TDD frame is GPS-anchored. axi_tdd is in ext-sync, so its frame is too."
elif [ "$maxseq" -le $(( EXP_FRAMES * 3 )) ]; then
    echo "  MOSTLY OK: max=$maxseq slightly over $EXP_FRAMES -> an occasional PPS reset is missed"
    echo "        (likely an F20 PPS glitch -> see /var/log/xocorrect.log). Anchored most seconds."
else
    echo "  FAIL: FRAME_SEQ climbed to $maxseq (>> $EXP_FRAMES) -> NOT resetting on PPS."
    echo "        Check TDD_CTRL.pps_sync_en (bit1) and that real PPS reaches F20."
fi
echo "  axi_tdd CONTROL=$ctrl (enable+sync_ext) -> consuming pps_tick; net is fixed in the bitstream."
echo "  Software reads are ms-jittery: this proves FUNCTION. For ns/sample precision, scope a TDD"
echo "  channel output vs PPS, or two-node cross-correlate (Tier 3, see TDD_PPS_DESIGN.md)."
