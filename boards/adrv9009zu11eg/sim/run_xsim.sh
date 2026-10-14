#!/usr/bin/env bash
# Simulate pps_counter + pps_rx_sync_mux + ADI util_ext_sync with the Vivado
# simulator (no license needed). Linux counterpart of run_xsim.ps1.
#
#   bash boards/adrv9009zu11eg/sim/run_xsim.sh <adi-hdl-root>
#
# Needs Vivado 2023.2 sourced (xvlog/xelab/xsim on PATH). Exit 0 = PASS.
set -euo pipefail
HDL=$(realpath "${1:?usage: $0 <adi-hdl-root>}")
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
WORK="$REPO/output/zu11eg-sim"
mkdir -p "$WORK" && cd "$WORK"
xvlog --nolog "$REPO/hdl/pps_counter/pps_counter.v" "$HERE/../hdl/pps_rx_sync_mux.v" \
    "$HDL/library/common/util_ext_sync.v" "$HERE/tb_rx_sync.v"
xelab --nolog -debug off tb_rx_sync -s tb_rx_sync
xsim --nolog tb_rx_sync -R | tee xsim.out
grep -q '^PASS tb_rx_sync' xsim.out
