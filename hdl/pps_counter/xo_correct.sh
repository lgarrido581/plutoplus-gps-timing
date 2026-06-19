#!/bin/sh
# xo_correct.sh - discipline the AD936x sample clock to GPS using the hardware
# PPS latch (pps_counter) + the ad9361 `xo_correction` knob.
#
# How it works: the hardware latch gives PPS_DELTA = sample-clock counts per GPS
# second (true 1 Hz from /dev/pps0's source). We compare it to the nominal rate
# and steer `xo_correction` (the driver's assumed TCXO frequency, in Hz) so the
# actual sample clock converges to nominal. The board's TCXO is NOT voltage-
# controlled (dcxo_tune is dead), so this corrects the divider math rather than
# pulling the crystal - which moves the synthesized sample/LO clocks onto GPS.
#
# Measured plant (xc7z010 Pluto+, 30.72 MHz): linear, monotonic, repeatable, with
#   slope ~= -0.767 counts/Hz  (1 count ~= 1.30 Hz of xo_correction, 0.025 ppm/Hz)
# so a near-deadbeat integral step + a 1-count deadband converges in ~1 update and
# then holds (no constant re-tuning of the RF datapath).
#
# Requires the --hwlatch bitstream (STATUS.pps_present==1) and a GPS PPS lock.
#
# Usage (on the Pluto):
#   sh xo_correct.sh            # run forever (daemon)
#   sh xo_correct.sh 8          # run 8 update cycles then exit (for testing)
#   NOMINAL=30720000 AVG=8 sh xo_correct.sh
set -u

PHY=/sys/bus/iio/devices/iio:device0
XO="$PHY/xo_correction"
STATUS=0x7C460008
DELTA=0x7C460014
SEQ=0x7C460018

NOMINAL="${NOMINAL:-30720000}"   # target sample-clock counts / GPS second
AVG="${AVG:-8}"                  # PPS edges averaged per update (beats ±1-count noise)
DEADBAND="${DEADBAND:-1}"        # |err| <= this many counts -> hold, don't re-tune
HZ_PER_CNT_X100="${HZ_PER_CNT_X100:-130}"  # 1.30 Hz per count (integer *100)
XO_MIN=39992000                  # from xo_correction_available
XO_MAX=40008000
ITERS="${1:-0}"                  # 0 = forever

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*"; }

[ "$(devmem $STATUS 32)" = "0x00000001" ] || { log "ERROR: PPS latch not present (STATUS != 1); is this the --hwlatch build with PPS on F20?"; exit 1; }

ps=""
avg_delta() {  # average AVG latched deltas (one per new PPS edge)
    i=0; sum=0
    while [ "$i" -lt "$AVG" ]; do
        s=$(devmem $SEQ 32)
        if [ "$s" != "$ps" ]; then
            d=$(devmem $DELTA 32)
            sum=$((sum + $((d))))
            ps="$s"; i=$((i + 1))
        fi
    done
    echo $((sum / AVG))
}
settle() {  # discard N edges after an xo write (PLL relock transient)
    k=0; while [ "$k" -lt "${1:-2}" ]; do s=$(devmem $SEQ 32); [ "$s" != "$ps" ] && { ps="$s"; k=$((k + 1)); }; done
}

log "start: NOMINAL=$NOMINAL AVG=$AVG DEADBAND=$DEADBAND xo=$(cat $XO)"
c=0
while :; do
    d=$(avg_delta)
    err=$((d - NOMINAL))                 # +ve = clock too fast
    ae=$err; [ "$ae" -lt 0 ] && ae=$((-ae))
    ppm=$(awk "BEGIN{printf \"%+.3f\", $err/($NOMINAL/1000000.0)}")
    xo=$(cat $XO)
    if [ "$ae" -gt "$DEADBAND" ]; then
        # plant slope is NEGATIVE (raising xo lowers delta), so to null err we
        # step xo the SAME sign as err: dxo = +err * (Hz per count).
        dxo=$(( err * HZ_PER_CNT_X100 / 100 ))    # Δxo Hz to null err
        nxo=$((xo + dxo))
        [ "$nxo" -lt "$XO_MIN" ] && nxo=$XO_MIN
        [ "$nxo" -gt "$XO_MAX" ] && nxo=$XO_MAX
        echo "$nxo" > "$XO"
        log "err=${err}cnt (${ppm}ppm) delta=$d  xo:$xo->$nxo (${dxo}Hz)  -> correcting"
        settle 2
    else
        log "err=${err}cnt (${ppm}ppm) delta=$d  xo=$xo  -> hold (deadband)"
    fi
    c=$((c + 1))
    [ "$ITERS" -ne 0 ] && [ "$c" -ge "$ITERS" ] && { log "done ($c cycles); xo=$(cat $XO)"; break; }
done
