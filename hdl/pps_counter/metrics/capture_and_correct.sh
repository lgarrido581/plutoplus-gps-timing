#!/bin/sh
# capture_and_correct.sh - capture PPS_DELTA while disciplining xo_correction.
#
# One cooperative loop (avoids two devmem-spinning processes competing): every
# GPS PPS edge it prints "pps_seq,pps_delta" (the "after" dataset), and every WIN
# edges it nudges the ad9361 `xo_correction` from the windowed-mean error to hold
# the sample clock on nominal. This is the exact run used for the post-correction
# metrics in README.md. See ../xo_correct.sh for the standalone disciplining loop
# and the plant characterization.
#
# Usage (on the Pluto, or piped over ssh):
#   sh capture_and_correct.sh 600 > corrected.csv
SEQ=0x7C460018; DELTA=0x7C460014
XO=/sys/bus/iio/devices/iio:device0/xo_correction
SRATE_F=/sys/bus/iio/devices/iio:device0/in_voltage_sampling_frequency
if sleep 0.2 2>/dev/null; then NAP="sleep 0.2"; else NAP="sleep 1"; fi

[ "$(devmem 0x7C460008 32)" = "0x00000001" ] || { echo "ERROR: PPS latch not present (STATUS!=1)" >&2; exit 1; }

# NOMINAL = counts/GPS-second = the AD936x l_clk. AUTO-DERIVE it from the sysfs
# sample rate x the measured l_clk multiple (1x in 1r1t, 2x in 2r2t), so it is correct
# in any mode without a human knowing to pass NOMINAL=61440000. Env-overridable.
derive_nominal() {
    sr=$(cat "$SRATE_F" 2>/dev/null); sr=$((sr)); [ "$sr" -gt 0 ] || sr=30720000
    i=0; dps=-1; vals=""
    while [ "$i" -lt 5 ]; do
        s=$(devmem $SEQ 32); s=$((s))
        if [ "$s" != "$dps" ]; then dps=$s; d=$(devmem $DELTA 32); vals="$vals $((d))"; i=$((i + 1)); else $NAP; fi
    done
    med=$(printf '%s\n' $vals | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    rx=$(( med * 1000 / sr )); m=1000; bd=2000000000
    for c in 500 1000 2000 4000; do dd=$((rx - c)); [ "$dd" -lt 0 ] && dd=$((-dd)); [ "$dd" -lt "$bd" ] && { bd=$dd; m=$c; }; done
    echo $(( sr * m / 1000 ))
}
NOMINAL="${NOMINAL:-$(derive_nominal)}"          # target counts / GPS second
DEADBAND="${DEADBAND:-1}"                        # |mean err| <= this -> hold (don't re-tune)
HZ="${HZ:-$(( 130 * 30720000 / NOMINAL ))}"      # 1.30 Hz/count at 30.72M, scaled to this rate
WIN="${WIN:-6}"                                  # edges per control update
XO_MIN=39992000; XO_MAX=40008000
N="${1:-600}"                                    # PPS edges to capture
echo "# nominal=$NOMINAL sample_rate=$(cat $SRATE_F 2>/dev/null) hz_per_cnt_x100=$HZ ts=$(date +%s)"

prev=-1; n=0; ssum=0; scount=0; settle=0
while [ "$n" -lt "$N" ]; do
    s=$(devmem $SEQ 32); sd=$((s))
    if [ "$sd" != "$prev" ]; then
        d=$(devmem $DELTA 32); dv=$((d))
        echo "$sd,$dv"
        prev=$sd; n=$((n + 1))
        if [ "$settle" -gt 0 ]; then settle=$((settle - 1));   # skip relock samples from control avg
        else ssum=$((ssum + dv - NOMINAL)); scount=$((scount + 1)); fi
        if [ "$scount" -ge "$WIN" ]; then
            err=$((ssum / scount)); ae=$err; [ "$ae" -lt 0 ] && ae=$((-ae))
            if [ "$ae" -gt "$DEADBAND" ]; then
                xo=$(cat $XO); nxo=$((xo + err * HZ / 100))
                [ "$nxo" -lt "$XO_MIN" ] && nxo=$XO_MIN
                [ "$nxo" -gt "$XO_MAX" ] && nxo=$XO_MAX
                echo "$nxo" > $XO; settle=2
            fi
            ssum=0; scount=0
        fi
        sleep 1
    fi
done
