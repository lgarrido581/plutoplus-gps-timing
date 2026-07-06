#!/bin/sh
# Runtime acceptance test for the LibreSDR AD9361 LVDS RX interface.
# Run while capture clients are idle. The kernel timing analysis mutes TX,
# injects RX PRBS, sweeps the 16x16 clock/data delay matrix, then restores the
# previous interface-delay and BIST settings.
set -eu

MIN_RUN="${MIN_RUN:-5}"  # ADI recommends a selected point with two taps per side.

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$(sed -n 's/^BOARD=//p' /etc/gps-timing-board 2>/dev/null)" = "libresdr" ] ||
    fail "this is not the LibreSDR image"
[ ! -e /tmp/pluto_ctld.capturing ] ||
    fail "a capture is active; retry when the capture service is idle"

PHY=""
RX=""
for d in /sys/bus/iio/devices/iio:device*; do
    case "$(cat "$d/name" 2>/dev/null)" in
        ad9361-phy) PHY="$d" ;;
        cf-ad9361-lpc) RX="$d" ;;
    esac
done
[ -n "$PHY" ] || fail "ad9361-phy is missing"
[ -n "$RX" ] || {
    dmesg | grep -iE 'ad9361_dig_tune|cf_axi_adc' | tail -20 >&2 || true
    fail "cf-ad9361-lpc is missing (RX digital tuning did not bind)"
}

if dmesg | grep -q 'Tuning RX FAILED'; then
    fail "kernel boot log contains an RX digital-tuning failure"
fi

DBG="/sys/kernel/debug/iio/$(basename "$PHY")/bist_timing_analysis"
[ -w "$DBG" ] && [ -r "$DBG" ] ||
    fail "timing-analysis debugfs entry is unavailable: $DBG"

SRATE=$(cat "$PHY/in_voltage_sampling_frequency" 2>/dev/null || echo unknown)
echo "LibreSDR LVDS acceptance: sample_rate=$SRATE"
echo 1 > "$DBG"
MATRIX=$(cat "$DBG")
printf '%s\n' "$MATRIX"

SUMMARY=$(printf '%s\n' "$MATRIX" | awk '
function max(a,b) { return a > b ? a : b }
/^[0-9a-f]:/ {
    row = substr($1, 1, 1)
    run = 0
    for (i = 2; i <= NF; i++) {
        col = i - 2
        if ($i == "o") {
            passes++
            run++
            hmax = max(hmax, run)
            vrun[col]++
            vmax = max(vmax, vrun[col])
        } else {
            run = 0
            vrun[col] = 0
        }
    }
    rows++
}
END {
    printf "rows=%d passes=%d max_horizontal=%d max_vertical=%d\n",
        rows, passes, hmax, vmax
    if (rows != 16 || passes == 0)
        exit 2
}') || fail "invalid or empty 16x16 PRBS timing matrix"
echo "$SUMMARY"

HMAX=$(echo "$SUMMARY" | sed -n 's/.*max_horizontal=\([0-9][0-9]*\).*/\1/p')
VMAX=$(echo "$SUMMARY" | sed -n 's/.*max_vertical=\([0-9][0-9]*\).*/\1/p')
[ "$HMAX" -ge "$MIN_RUN" ] || [ "$VMAX" -ge "$MIN_RUN" ] ||
    fail "PRBS eye has no run of $MIN_RUN passing delay settings"

rm -f /tmp/libresdr-rx-test.iq
iio_readdev -s 8192 -b 8192 cf-ad9361-lpc voltage0 voltage1 \
    > /tmp/libresdr-rx-test.iq 2>/tmp/libresdr-rx-test.err ||
    fail "two-channel RX capture failed: $(cat /tmp/libresdr-rx-test.err)"
BYTES=$(wc -c < /tmp/libresdr-rx-test.iq)
[ "$BYTES" -gt 0 ] || fail "two-channel RX capture returned no data"
rm -f /tmp/libresdr-rx-test.iq /tmp/libresdr-rx-test.err

echo "PASS: LVDS PRBS eye has >=$MIN_RUN consecutive settings; two-channel RX captured $BYTES bytes"
