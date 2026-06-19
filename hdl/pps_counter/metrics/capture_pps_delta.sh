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
