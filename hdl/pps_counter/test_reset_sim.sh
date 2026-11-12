#!/bin/bash
# Run with Vivado's simulation tools on PATH; all output stays in a temp dir.
set -euo pipefail
rtl_dir=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
cd "$scratch"
xvlog --sv "$rtl_dir/pps_counter.v" "$rtl_dir/tb_pps_reset.sv"
xelab tb_pps_reset -s pps_reset_test
xsim pps_reset_test -runall | tee simulation.log
grep -q PPS_RESET_AND_EDGE_TEST_PASS simulation.log
