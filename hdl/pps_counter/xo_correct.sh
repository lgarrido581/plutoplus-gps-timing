#!/bin/sh
# xo_correct.sh - discipline the AD936x sample clock to GPS using the hardware
# PPS latch (pps_counter) + the ad9361 `xo_correction` knob.
#
# How it works: the hardware latch gives PPS_DELTA = sample-clock counts per GPS
# second (true 1 Hz from /dev/pps0's source). We compare it to the nominal rate
# and steer `xo_correction` (the driver's assumed TCXO frequency, in Hz) so the
# actual sample clock converges to nominal. This backend corrects the AD936x
# divider math rather than pulling the crystal. That is required on Pluto+,
# whose TCXO is not voltage-controlled, and remains the fallback on LibreSDR
# until its external VCTCXO DAC has a separate control backend.
#
# Measured plant: linear, monotonic, and repeatable. Pluto+ measured about
# 1.30 Hz of xo_correction per count at 30.72 MHz; LibreSDR measured 0.3282
# Hz/count at 122.88 MHz (= 1.313 Hz/count when normalized to 30.72 MHz).
# A near-deadbeat integral step converges in about one update. Corrections below
# the integer-Hz actuator resolution are held without rewriting the RF datapath.
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
# HOLDOVER + timing-quality: if PPS edges stop for >=PPS_TIMEOUT s, the loop FREEZES
# xo_correction at its last good value (the TCXO free-runs at the last-disciplined
# frequency) and publishes a state to STATE_FILE (default /run/xo_state) that the node
# agent / coordinator reads to weight or drop this node:
#   LOCKED | CORRECTING | PPS_GLITCH | HOLDOVER_GOOD | HOLDOVER_DEGRADED | INVALID
# Holdover escalates GOOD->DEGRADED->INVALID by elapsed time (HOLD_GOOD_S, HOLD_INVALID_S;
# tune from metrics/ ADEV against your TDOA budget). On PPS return it re-acquires cleanly.
# NOTE: the TCXO only holds fine (sub-sample) timing for ~seconds; long holdover needs an
# external OCXO/Rb reference (see ROADMAP). State file line:
#   state=LOCKED holdover_s=0 xo=39999704 nominal=30720000 last_delta=30720000 last_ppm=+0.000 ts=...
#
# Usage (on the Pluto):
#   sh xo_correct.sh            # run forever (daemon); NOMINAL auto-derived
#   sh xo_correct.sh 8          # run 8 update cycles then exit (for testing)
#   HOLD_GOOD_S=5 HOLD_INVALID_S=60 STATE_FILE=/run/xo_state sh xo_correct.sh
#   NOMINAL=61440000 sh xo_correct.sh   # pin nominal, skip auto-derive
#
# Optional persistent overrides may be placed in /etc/default/xocorrect (or the
# path in XO_CORRECT_CONFIG).
[ -r "${XO_CORRECT_CONFIG:-/etc/default/xocorrect}" ] &&
    . "${XO_CORRECT_CONFIG:-/etc/default/xocorrect}"
set -u

scale_gain_milli() {
    gain=$((1313 * 30720000 / $1))
    [ "$gain" -lt 1 ] && gain=1
    echo "$gain"
}
calc_dxo() {
    echo $(($1 * $2 / 1000))
}

# Hardware-free regression check for the rate-scaled gain and integer actuator
# threshold. Kept in the production script so the tested math cannot drift.
if [ "${XO_CORRECT_SELFTEST:-0}" = 1 ]; then
    [ "$(scale_gain_milli 30720000)" = 1313 ]
    [ "$(scale_gain_milli 122880000)" = 328 ]
    [ "$(calc_dxo 3 328)" = 0 ]
    [ "$(calc_dxo 4 328)" = 1 ]
    [ "$(calc_dxo -4 328)" = -1 ]
    echo "xo_correct math self-test: PASS"
    exit 0
fi

PHY=""
for d in /sys/bus/iio/devices/iio:device*; do
    [ "$(cat "$d/name" 2>/dev/null)" = "ad9361-phy" ] && { PHY="$d"; break; }
done
[ -n "$PHY" ] || { echo "ERROR: ad9361-phy IIO device not found"; exit 1; }
XO="$PHY/xo_correction"
SRATE="$PHY/in_voltage_sampling_frequency"   # live RX sample rate (Hz); l_clk derives from it
STATUS=0x7C460008
DELTA=0x7C460014
SEQ=0x7C460018

NOMINAL_ENV="${NOMINAL:-}"       # if set, pin nominal & skip auto-derive; else derive at startup
AVG="${AVG:-8}"                  # PPS edges averaged per update (beats ±1-count noise)
DEADBAND="${DEADBAND:-1}"        # |err| <= this many counts -> hold, don't re-tune
# Use milli-Hz/count so the LibreSDR 4x-clock case retains enough precision.
# HZ_PER_CNT_X100 remains accepted for backward compatibility.
if [ -n "${HZ_PER_CNT_X1000:-}" ]; then
    HZ_PER_CNT_ENV="$HZ_PER_CNT_X1000"
elif [ -n "${HZ_PER_CNT_X100:-}" ]; then
    HZ_PER_CNT_ENV=$((HZ_PER_CNT_X100 * 10))
else
    HZ_PER_CNT_ENV=""
fi
# Outlier rejection: a trusted delta is NOMINAL ± MAXPPM. A missed/spurious PPS edge
# makes the latch span multiple seconds -> delta is millions of counts off, which
# (un-rejected) poisons the average and rails xo_correction. MAXDEV is derived from
# MAXPPM once NOMINAL is known (so it scales with the clock rate).
MAXPPM="${MAXPPM:-300}"          # |delta-NOMINAL| beyond this many ppm = outlier (TCXO is <±25)
REJECT_MAX="${REJECT_MAX:-16}"   # outliers tolerated per update before giving up -> hold
REDERIVE_AFTER="${REDERIVE_AFTER:-3}"  # consecutive all-outlier updates before re-deriving NOMINAL
XO_AVAIL="$PHY/xo_correction_available"
XO_MIN=$(awk '{gsub(/^\[/, "", $1); print $1}' "$XO_AVAIL" 2>/dev/null)
XO_MAX=$(awk '{gsub(/\]$/, "", $NF); print $NF}' "$XO_AVAIL" 2>/dev/null)
case "$XO_MIN" in ''|*[!0-9]*) XO_MIN=39992000 ;; esac
case "$XO_MAX" in ''|*[!0-9]*) XO_MAX=40008000 ;; esac
ITERS="${1:-0}"                  # 0 = forever
# Set by derive_nominal()/recompute_thresholds() below:
NOMINAL=30720000; MAXDEV=9000; HZ_PER_CNT_X1000=1313

# Poll loops below wait for PPS_SEQ to change (once/sec). Without a sleep they
# fork devmem in a tight loop and peg a CPU core. Use a fractional sleep; fall
# back to 1s if this busybox lacks fractional sleep (still kills the busy-loop).
if sleep 0.1 2>/dev/null; then NAP="sleep 0.2"; else NAP="sleep 1"; fi

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*"; }

# Timing-quality state for the node agent / coordinator (see ROADMAP holdover work).
# States: LOCKED | CORRECTING | PPS_GLITCH | HOLDOVER_GOOD | HOLDOVER_DEGRADED | INVALID.
# Atomic write (temp+mv) so a reader never sees a half-line. Logs on state change.
prev_state=""
write_state() {  # $1=state  $2=holdover_elapsed_s
    printf 'state=%s holdover_s=%s xo=%s nominal=%s last_delta=%s last_ppm=%s ts=%s\n' \
        "$1" "${2:-0}" "$(cat $XO 2>/dev/null)" "$NOMINAL" "${last_delta:-NA}" "${last_ppm:-NA}" "$(date +%s)" \
        > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null
    # log transitions into ABNORMAL states only (LOCKED/CORRECTING are already logged by the loop)
    if [ "$1" != "$prev_state" ]; then
        case "$1" in LOCKED|CORRECTING) : ;; *) log "state -> $1${2:+ (holdover ${2}s)}" ;; esac
    fi
    prev_state="$1"
}

[ "$(devmem $STATUS 32)" = "0x00000001" ] || { log "ERROR: PPS latch not present (STATUS != 1); verify the PPS input and FPGA timing build"; exit 1; }

ps=""
avg_delta() {  # average AVG in-range latched deltas; skip missed-edge outliers.
    # Echoes the average, or "BAD" if more than REJECT_MAX outliers arrive before
    # AVG good samples (PPS missing/glitching) -> caller holds last good xo.
    # Echoes "NOPPS" if no new edge arrives within PPS_TIMEOUT s (-> holdover).
    i=0; sum=0; rej=0; wt=$(date +%s)
    while [ "$i" -lt "$AVG" ]; do
        s=$(devmem $SEQ 32)
        if [ "$s" != "$ps" ]; then
            ps="$s"; wt=$(date +%s)          # got an edge -> reset the no-PPS timer
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
            [ $(( $(date +%s) - wt )) -ge "$PPS_TIMEOUT" ] && { echo NOPPS; return; }
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
    if [ -n "$HZ_PER_CNT_ENV" ]; then HZ_PER_CNT_X1000="$HZ_PER_CNT_ENV"
    else HZ_PER_CNT_X1000=$(scale_gain_milli "$NOMINAL"); fi
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
        log "WARN: could not measure l_clk (PPS present?); NOMINAL=$NOMINAL (sample_rate=$S)"
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
# --- holdover / timing-quality (see ROADMAP "Holdover handling") ---
PPS_TIMEOUT="${PPS_TIMEOUT:-3}"          # s with no new PPS edge -> declare holdover
HOLD_GOOD_S="${HOLD_GOOD_S:-10}"         # holdover < this -> GOOD; tune from metrics/ ADEV + your TDOA budget
HOLD_INVALID_S="${HOLD_INVALID_S:-300}"  # holdover >= this -> INVALID (coordinator should drop the node)
STATE_FILE="${STATE_FILE:-/run/xo_state}"  # the node agent / coordinator reads this
log "start: NOMINAL=$NOMINAL AVG=$AVG DEADBAND=$DEADBAND MAXDEV=$MAXDEV gain=${HZ_PER_CNT_X1000}/1000 xo_range=${XO_MIN}..${XO_MAX} xo=$(cat $XO)"
c=0; last=""; holdc=0; badstreak=0; holdstart=0; last_delta=NA; last_ppm=NA
while :; do
    d=$(avg_delta)
    if [ "$d" = "NOPPS" ]; then          # no PPS edges -> HOLDOVER: freeze xo, flag by elapsed time
        now=$(date +%s)
        [ "$holdstart" = 0 ] && { holdstart=$now; log "WARN: no PPS for >=${PPS_TIMEOUT}s -> HOLDOVER; freezing xo=$(cat $XO)"; }
        el=$(( now - holdstart ))
        if   [ "$el" -lt "$HOLD_GOOD_S" ];    then st=HOLDOVER_GOOD
        elif [ "$el" -lt "$HOLD_INVALID_S" ]; then st=HOLDOVER_DEGRADED
        else                                        st=INVALID
        fi
        write_state "$st" "$el"          # xo is left untouched (frozen at last good value)
        last=correct; holdc=0
        c=$((c + 1))
        [ "$ITERS" -ne 0 ] && [ "$c" -ge "$ITERS" ] && { log "done ($c cycles); xo=$(cat $XO)"; break; }
        continue
    fi
    # any real reading (number or BAD) means PPS edges are arriving again
    [ "$holdstart" != 0 ] && { log "PPS recovered after $(( $(date +%s) - holdstart ))s holdover -> re-acquiring"; holdstart=0; }
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
        write_state PPS_GLITCH 0
        last=correct; holdc=0            # force a "locked, holding" log on the next good update
        c=$((c + 1))
        [ "$ITERS" -ne 0 ] && [ "$c" -ge "$ITERS" ] && { log "done ($c cycles); xo=$(cat $XO)"; break; }
        continue
    fi
    badstreak=0                          # got a good update -> clear the anomaly streak
    err=$((d - NOMINAL))                 # +ve = clock too fast
    ae=$err; [ "$ae" -lt 0 ] && ae=$((-ae))
    ppm=$(awk "BEGIN{printf \"%+.3f\", $err/($NOMINAL/1000000.0)}")
    last_delta=$d; last_ppm=$ppm
    xo=$(cat $XO)
    dxo=0
    [ "$ae" -gt "$DEADBAND" ] && dxo=$(calc_dxo "$err" "$HZ_PER_CNT_X1000")
    if [ "$dxo" -ne 0 ]; then
        # Plant slope is negative (raising xo lowers delta), so step xo in the
        # same direction as err. Clamp to this device's advertised range.
        nxo=$((xo + dxo))
        [ "$nxo" -lt "$XO_MIN" ] && nxo=$XO_MIN
        [ "$nxo" -gt "$XO_MAX" ] && nxo=$XO_MAX
        if [ "$nxo" -ne "$xo" ]; then
            echo "$nxo" > "$XO"
            log "err=${err}cnt (${ppm}ppm) delta=$d  xo:$xo->$nxo (${dxo}Hz)  -> correcting"
            write_state CORRECTING 0
            settle 2
            last=correct; holdc=0
        else
            log "WARN: err=${err}cnt (${ppm}ppm) but xo=$xo is at limit; holding without rewrite"
            write_state CORRECTING 0
            last=limit; holdc=0
        fi
    else
        # The error is inside DEADBAND or below the integer-Hz actuator
        # resolution. Never rewrite the same value: that can relock the PLL.
        if [ "$last" != "hold" ] || [ $((holdc % HEARTBEAT)) -eq 0 ]; then
            log "err=${err}cnt (${ppm}ppm) delta=$d  xo=$xo  -> locked, holding (sub-step)"
        fi
        write_state LOCKED 0
        last=hold; holdc=$((holdc + 1))
    fi
    c=$((c + 1))
    [ "$ITERS" -ne 0 ] && [ "$c" -ge "$ITERS" ] && { log "done ($c cycles); xo=$(cat $XO)"; break; }
done
