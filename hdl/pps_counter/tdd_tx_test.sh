#!/bin/sh
# tdd_tx_test.sh - set up a GPS-aligned, TDD-gated TX burst so you can MEASURE
# TX-vs-PPS timing on a scope. Runs ON THE PLUTO. Needs the v1.4 --hwlatch
# GPS-aligned-TDD bitstream (axi_tdd synced from pps_counter/pps_tick) + PPS lock.
#
# There is no pure-software way to measure TX-vs-PPS in nanoseconds: you must see
# the RF edge against the PPS edge. This script makes a clean, GPS-anchored TX
# burst; you read the timing on a 2-channel oscilloscope:
#
#   Ch1 = GPS 1PPS     (probe the PPS line feeding F20, or the GPS module's PPS pin)
#   Ch2 = Pluto TX SMA (the TDD-gated tone; use a coax + attenuator or a sniff probe)
#   Trigger on Ch1 (PPS) rising edge, then read:
#     * delay PPS -> TX-rising  = fixed pipeline latency (axi_tdd + AD9361 + RF),
#                                 ~constant per node (the per-node calibration term)
#     * jitter of that delay    = sync jitter, expect <= 1 sample (~32.6 ns @ 30.72M)
#     * drift over minutes      = sample-clock lock quality (near 0 once xo_correct locks)
#
# In a TDOA network this fixed delay cancels in a time-DIFFERENCE only if it is
# characterized per node (see ROADMAP "per-node fixed-delay calibration").
#
# Usage:  sh tdd_tx_test.sh                 # 100 ms frame (10 Hz burst), 1 GHz, 1 MHz tone
#         FRAME_MS=100 TX_LO=915000000 TONE_HZ=2000000 sh tdd_tx_test.sh
set -u

# ---- axi_tdd (0x7C440000) ----
T_CONTROL=0x7C440040; T_CHEN=0x7C440044; T_FRAMELEN=0x7C440054
T_CH0_ON=0x7C440080;  T_CH0_OFF=0x7C440084
# ---- pps_counter (0x7C460000) ----
P_ID=0x7C460000; P_STATUS=0x7C460008; P_PPSDELTA=0x7C460014; P_PPSSEQ=0x7C460018
SRATE_F=/sys/bus/iio/devices/iio:device0/in_voltage_sampling_frequency  # authoritative AD936x rate
FRAME_MS="${FRAME_MS:-100}"          # frame length in ms (TX on for first half)
TX_LO="${TX_LO:-1000000000}"         # TX LO in Hz (shown in the pyadi snippet below)
TONE_HZ="${TONE_HZ:-1000000}"        # DDS tone offset in Hz (shown in the snippet)

rd() { devmem "$1" 32; }
wr() { devmem "$1" 32 "$2"; }

echo "=== tdd_tx_test: GPS-aligned TDD-gated TX burst (scope PPS vs TX) ==="
[ "$(rd $P_ID)" = "0x50505343" ] || { echo "pps_counter ID != PPSC -> need the --hwlatch v1.4 bitstream. abort"; exit 1; }

# authoritative sample rate from sysfs (no PPS needed); the system-of-systems tracks this per node
SR=$(cat "$SRATE_F" 2>/dev/null); SR=$(( ${SR:-0} + 0 ))
[ "$SR" -gt 0 ] && echo "  AD936x RX sample rate (sysfs) = $SR Hz"

# require LIVE PPS (PPS_SEQ advancing) before measuring vs TX; PPS_DELTA alone is sticky/stale
q0=$(( $(rd $P_PPSSEQ) )); sleep 3; q1=$(( $(rd $P_PPSSEQ) ))
[ $(( q1 - q0 )) -ge 1 ] || { echo "NO LIVE PPS (PPS_SEQ not advancing) -> the burst won't be GPS-anchored. Fix the F20 PPS path (run tdd_verify.sh). abort"; exit 2; }

FS=$(( $(rd $P_PPSDELTA) ))   # l_clk in counts/sec (PPS is live, so this is current)
[ "$FS" -gt 1000000 ] || { echo "PPS_DELTA=$FS implausible; abort"; exit 1; }
[ "$SR" -gt 0 ] && echo "  l_clk (from PPS) = $FS Hz = ~$(( FS * 100 / SR ))/100 x sample rate"
FRAME_LEN=$(( FS * FRAME_MS / 1000 ))
echo "  frame=${FRAME_MS}ms=$FRAME_LEN samples; TX on for first half ($((FRAME_LEN/2)) samples)"

# ---- you need an active TX signal for the gate to chop into bursts ----
# The TDD gate (channel 0 -> TX data) bursts WHATEVER TX signal is running. Start one
# any way you like; simplest is a DDS tone. On-device DDS attribute names vary by fw,
# so this just PRINTS the options rather than guessing (the gating below is the part
# this script reliably sets up):
echo "  --- start a TX tone first (so there's RF to scope), e.g. from a host with pyadi: ---"
echo "      python3 - <<'PY'"
echo "      import adi; sdr=adi.Pluto('ip:pluto.local')"
echo "      sdr.tx_lo=$TX_LO; sdr.tx_cyclic_buffer=True; sdr.tx_hardwaregain_chan0=-10"
echo "      import numpy as np; n=2**14; t=np.arange(n)/sdr.sample_rate"
echo "      sdr.tx(0.5*2**14*np.exp(2j*np.pi*$TONE_HZ*t))   # 1 MHz tone, runs until stopped"
echo "      PY"
echo "      (or a GNU Radio sig source -> Pluto sink. The TDD gate chops it into bursts.)"

# ---- configure axi_tdd: gate channel 0 (-> TX data) for the first half of each frame ----
wr $T_CONTROL 0x0                    # disable while configuring (regs are write-locked when enabled)
wr $T_FRAMELEN $(( FRAME_LEN - 1 ))  # axi_tdd frame length is (cycles - 1)
wr $T_CH0_ON  0x0                    # TX window opens at frame start (PPS-anchored edge)
wr $T_CH0_OFF $(( FRAME_LEN / 2 ))   # ...closes at the half-frame
wr $T_CHEN    0x1                    # enable channel 0
wr $T_CONTROL 0x9                    # enable(b0) + sync_ext(b3): frame re-anchors on pps_tick
echo "  axi_tdd CONTROL=$(rd $T_CONTROL) (expect 0x9)  CH_ENABLE=$(rd $T_CHEN)"

echo
echo "=== now scope it ==="
echo "  Ch1 = GPS 1PPS,  Ch2 = Pluto TX SMA,  trigger on Ch1 rising."
echo "  The TX tone bursts at ${FRAME_MS}ms; every $(( 1000 / FRAME_MS ))th burst starts on the PPS edge."
echo "  Measure PPS->TX-rising delay (fixed latency) + its jitter (<=1 sample ~32.6ns) + drift."
echo
echo "  PPS-loss test: unplug/disable PPS and watch 'sh tdd_verify.sh' -> FRAME_SEQ keeps advancing"
echo "  (axi_tdd free-runs; bursts continue, just un-anchored) until PPS returns and re-aligns."
