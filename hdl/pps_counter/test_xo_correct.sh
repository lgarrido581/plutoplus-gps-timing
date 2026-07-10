#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

XO_CORRECT_SELFTEST=1 sh "$HERE/xo_correct.sh"
sh -n "$HERE/xo_correct.sh"
sh -n "$HERE/metrics/capture_and_correct.sh"

echo "xo_correct regression tests: PASS"
