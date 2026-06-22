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
# NOMINAL is the expected counts/sec = the counter clock (axi_ad9361 l_clk). That is
# NOT fixed by the bitstream: l_clk = sample_rate x (data-clock multiple), both set at
# RUNTIME by the AD9361 config. So two boards on identical firmware can clock the
# counter differently (e.g. 30.72 vs 61.44 MHz if one runs a 2x data-clock / different
# sample rate). Hard-coding NOMINAL=30.72M then reads a +1e6 ppm "error" and rails the
# knob. Instead we AUTO-DERIVE NOMINAL at startup from the live sample rate x the
# measured l_clk/rate ratio, scale the plant gain + outlier band to it, and RE-DERIVE
# if sustained anomalies appear (operator changed the sample rate mid-run).
#
# Requires the --hwlatch bitstream (STATUS.pps_present==1) and a GPS PPS lock.
#
# Usage (on the Pluto):
#   sh xo_correct.sh            # run forever (daemon); NOMINAL auto-derived
#   sh xo_correct.sh 8          # run 8 update cycles then exit (for testing)
#   NOMINAL=61440000 sh xo_correct.sh   # pin nominal, skip auto-derive
set -u

PHY=/sys/bus/iio/devices/iio:device0
XO="$PHY/xo_correction"
SRATE="$PHY/in_voltage_sampling_frequency"   # live RX sample rate (Hz); l_clk derives from it
STATUS=0x7C460008
DELTA=0x7C460014
SEQ=0x7C460018

NOMINAL_ENV="${NOMINAL:-}"       # if set, pin nominal & skip auto-derive; else derive at startup
AVG="${AVG:-8}"                  # PPS edges averaged per update (beats ±1-count noise)
DEADBAND="${DEADBAND:-1}"        # |err| <= this many counts -> hold, don't re-tune
HZ_PER_CNT_ENV="${HZ_PER_CNT_X100:-}"   # plant-gain override; else scaled from the 30.72M calib
# Outlier rejection: a trusted delta is NOMINAL ± MAXPPM. A missed/spurious PPS edge
# makes the latch span multiple seconds -> delta is millions of counts off, which
# (un-rejected) poisons the average and rails xo_correction. MAXDEV is derived from
# MAXPPM once NOMINAL is known (so it scales with the clock rate).
MAXPPM="${MAXPPM:-300}"          # |delta-NOMINAL| beyond this many ppm = outlier (TCXO is <±25)
REJECT_MAX="${REJECT_MAX:-16}"   # outliers tolerated per update before giving up -> hold
REDERIVE_AFTER="${REDERIVE_AFTER:-3}"  # consecutive all-outlier updates before re-deriving NOMINAL
XO_MIN=39992000                  # from xo_correction_available
XO_MAX=40008000
ITERS="${1:-0}"                  # 0 = forever
# Set by derive_nominal()/recompute_thresholds() below:
NOMINAL=30720000; MAXDEV=9000; HZ_PER_CNT_X100=130

# Poll loops below wait for PPS_SEQ to change (once/sec). Without a sleep they
# fork devmem in a tight loop and peg a CPU core. Use a fractional sleep; fall
# back to 1s if this busybox lacks fractional sleep (still kills the busy-loop).
if sleep 0.1 2>/dev/null; then NAP="sleep 0.2"; else NAP="sleep 1"; fi

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*"; }

[ "$(devmem $STATUS 32)" = "0x00000001" ] || { log "ERROR: PPS latch not present (STATUS != 1); is this the --hwlatch build with PPS on F20?"; exit 1; }

ps=""
avg_delta() {  # average AVG in-range latched deltas; skip missed-edge outliers.
    # Echoes the average, or "BAD" if more than REJECT_MAX outliers arrive before
    # AVG good samples (PPS missing/glitching) -> caller holds last good xo.
    i=0; sum=0; rej=0
    while [ "$i" -lt "$AVG" ]; do
        s=$(devmem $SEQ 32)
        if [ "$s" != "$ps" ]; then
            ps="$s"
            d=$(devmem $DELTA 32); d=$((d))
            dev=$((d - NOMINAL)); [ "$dev" -lt 0 ] && dev=$((-dev))
            if [ "$dev" -le "$MAXDEV" ]; then
                sum=$((sum + d)); i=$((i + 1))
            else
                rej=$((rej + 1))
                [ "$rej" -ge "$REJECT_MAX" ] && { echo BAD; return; }
            fi
        else
            $NAP
        fi
    done
    echo $((sum / AVG))
}
settle() {  # discard N edges after an xo write (PLL relock transient)
    k=0; while [ "$k" -lt "${1:-2}" ]; do s=$(devmem $SEQ 32); if [ "$s" != "$ps" ]; then ps="$s"; k=$((k + 1)); else $NAP; fi; done
}
read_srate() {  # live RX sample rate in Hz (fallback 30.72M if attr missing)
    s=$(cat "$SRATE" 2>/dev/null); s=$((s)); [ "$s" -gt 0 ] && echo "$s" || echo 30720000
}
recompute_thresholds() {  # scale outlier band + plant gain to the current NOMINAL
    MAXDEV=$(( NOMINAL / 1000000 * MAXPPM )); [ "$MAXDEV" -lt 2000 ] && MAXDEV=2000
    # err counts scale with NOMINAL, so Hz-per-count scales as 1/NOMINAL vs the 30.72M calib
    if [ -n "$HZ_PER_CNT_ENV" ]; then HZ_PER_CNT_X100="$HZ_PER_CNT_ENV"
    else HZ_PER_CNT_X100=$(( 130 * 30720000 / NOMINAL )); [ "$HZ_PER_CNT_X100" -lt 1 ] && HZ_PER_CNT_X100=1; fi
}
derive_nominal() {  # NOMINAL = sample_rate x (measured l_clk/rate multiple, snapped to .5/1/2/4)
    S=$(read_srate)
    raw=""; n=0; tries=0   # median of up to 9 RAW deltas -> robust to glitches
    while [ "$n" -lt 9 ] && [ "$tries" -lt 80 ]; do
        s=$(devmem $SEQ 32)
        if [ "$s" != "$ps" ]; then ps="$s"; d=$(devmem $DELTA 32); raw="$raw
$((d))"; n=$((n + 1)); else $NAP; fi
        tries=$((tries + 1))
    done
    if [ "$n" -lt 3 ]; then
        NOMINAL=${NOMINAL_ENV:-$S}
        log "WARN: could not measure l_clk (PPS present? STATUS/F20); NOMINAL=$NOMINAL (sample_rate=$S)"
        recompute_thresholds; return
    fi
    med=$(printf '%s\n' "$raw" | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    rx=$(( med * 1000 / S ))     # l_clk/rate ratio x1000
    M=1000; bd=2000000000
    for cnd in 500 1000 2000 4000; do dd=$((rx - cnd)); [ "$dd" -lt 0 ] && dd=$((-dd)); [ "$dd" -lt "$bd" ] && { bd=$dd; M=$cnd; }; done
    NOMINAL=$(( S * M / 1000 ))
    log "derived NOMINAL=$NOMINAL (sample_rate=$S, l_clk=${M}/1000 x rate, median raw delta=$med over $n)"
    recompute_thresholds
}

# Establish NOMINAL (+ scaled thresholds) before disciplining.
if [ -n "$NOMINAL_ENV" ]; then NOMINAL="$NOMINAL_ENV"; recompute_thresholds; log "NOMINAL pinned from env: $NOMINAL"
else derive_nominal; fi

HEARTBEAT="${HEARTBEAT:-450}"   # log a "holding" heartbeat every N held cycles
log "start: NOMINAL=$NOMINAL AVG=$AVG DEADBAND=$DEADBAND MAXDEV=$MAXDEV gain=${HZ_PER_CNT_X100}/100 xo=$(cat $XO)"
c=0; last=""; holdc=0; badstreak=0
while :; do
    d=$(avg_delta)
    if [ "$d" = "BAD" ]; then            # this update was all outliers -> hold, maybe re-derive
        xo=$(cat $XO)
        badstreak=$((badstreak + 1))
        log "WARN: >=${REJECT_MAX} outlier deltas (>${MAXDEV}cnt off NOMINAL=$NOMINAL); missed/spurious PPS or rate change -> holding xo=$xo"
        # Sustained outliers usually mean the sample rate (hence l_clk/NOMINAL) changed
        # under us, not noise. Re-derive; if NOMINAL moved, the loop re-locks to it.
        if [ -z "$NOMINAL_ENV" ] && [ "$badstreak" -ge "$REDERIVE_AFTER" ]; then
            oldn=$NOMINAL
            log "anomaly: $badstreak consecutive outlier updates -> re-checking sample rate"
            derive_nominal
            [ "$NOMINAL" != "$oldn" ] && log "NOMINAL changed $oldn -> $NOMINAL (sample-rate change); re-locking"
            badstreak=0
        fi
        last=correct; holdc=0            # force a "locked, holding" log on the next good update
        c=$((c + 1))
        [ "$ITERS" -ne 0 ] && [ "$c" -ge "$ITERS" ] && { log "done ($c cycles); xo=$(cat $XO)"; break; }
        continue
    fi
    badstreak=0                          # got a good update -> clear the anomaly streak
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
        last=correct; holdc=0
    else
        # log holds only on the lock transition + a periodic heartbeat, so a
        # long-running daemon doesn't fill the log every cycle.
        if [ "$last" != "hold" ] || [ $((holdc % HEARTBEAT)) -eq 0 ]; then
            log "err=${err}cnt (${ppm}ppm) delta=$d  xo=$xo  -> locked, holding"
        fi
        last=hold; holdc=$((holdc + 1))
    fi
    c=$((c + 1))
    [ "$ITERS" -ne 0 ] && [ "$c" -ge "$ITERS" ] && { log "done ($c cycles); xo=$(cat $XO)"; break; }
done
