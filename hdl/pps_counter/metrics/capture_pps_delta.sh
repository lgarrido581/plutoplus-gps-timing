#!/bin/sh
# capture_pps_delta.sh - capture the hardware-latched PPS_DELTA on the Pluto+.
#
# Emits one CSV line per GPS PPS edge:  pps_seq,pps_delta
#   pps_seq   = PPS edge index (one per GPS second) -> use as the time axis
#   pps_delta = AD936x sample-clock counts latched between this edge and the last
#               (== cnt_clk Hz; nominal 30,720,000 at the default 30.72 MHz rate)
#
# Requires the --hwlatch bitstream (pps_in wired to F20); on the software-latch
# build PPS_DELTA stays 0. Reads the AXI-Lite regs via devmem (no python on device).
#
# Usage (run ON the Pluto, or pipe over ssh):
#   sh capture_pps_delta.sh 600 > baseline.csv          # 600 edges (~10 min)
#   ssh root@pluto.local 'sh -s' < capture_pps_delta.sh 600 > baseline.csv
#
# It dedupes by PPS_SEQ so every line is a distinct, hardware-latched edge.
SEQ=0x7C460018      # PPS_SEQ   - rising-edge counter
DELTA=0x7C460014    # PPS_DELTA - counts since previous edge

N="${1:-600}"       # number of PPS edges to capture (default 600 ~= 10 min)
SRATE_F=/sys/bus/iio/devices/iio:device0/in_voltage_sampling_frequency
if sleep 0.2 2>/dev/null; then NAP="sleep 0.2"; else NAP="sleep 1"; fi

# Header: record the rate so analyze.py uses it (1x in 1r1t, 2x in 2r2t) instead of
# assuming 30.72M. NOMINAL = sysfs sample_rate x the measured l_clk multiple.
sr=$(cat "$SRATE_F" 2>/dev/null); sr=$((sr)); [ "$sr" -gt 0 ] || sr=30720000
i=0; dps=-1; vals=""
while [ "$i" -lt 5 ]; do
    s=$(devmem $SEQ 32); s=$((s))
    if [ "$s" != "$dps" ]; then dps=$s; d=$(devmem $DELTA 32); vals="$vals $((d))"; i=$((i + 1)); else $NAP; fi
done
med=$(printf '%s\n' $vals | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
rx=$(( med * 1000 / sr )); m=1000; bd=2000000000
for c in 500 1000 2000 4000; do dd=$((rx - c)); [ "$dd" -lt 0 ] && dd=$((-dd)); [ "$dd" -lt "$bd" ] && { bd=$dd; m=$c; }; done
echo "# nominal=$(( sr * m / 1000 )) sample_rate=$sr ts=$(date +%s)"

prev=-1
n=0
while [ "$n" -lt "$N" ]; do
    s=$(devmem $SEQ 32)
    sd=$((s))
    if [ "$sd" != "$prev" ]; then
        d=$(devmem $DELTA 32)
        echo "$sd,$((d))"
        prev=$sd
        n=$((n + 1))
        sleep 1     # next edge is ~1 s away; coarse-wait then tight-poll for it
    fi
done
