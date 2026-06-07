#!/bin/sh
# Capture a raw IQ block ON THE PLUTO and bracket it with the chrony/PPS-
# disciplined GPS system time. Proves a (software) timestamp can be attached to
# the captured data using GPS-true time.
#
# IMPORTANT: the Pluto IQ stream has NO hardware-embedded per-sample timestamp.
# This attaches a SOFTWARE timestamp (CLOCK_REALTIME) around the capture. It is
# GPS-accurate to ~milliseconds (USB + OS jitter) -- good for coarse capture
# windows, NOT for fine TDOA. Fine sample alignment needs a PPS marker injected
# into RX or a shared reference signal (see tdoa/README.md).
#
# Run this ON the Pluto (ssh root@pluto.local). No extra dependencies.
#
# Usage: ./capture_gps_timestamped.sh [center_hz] [rate_hz] [nsamples] [outfile]

FC=${1:-100000000}      # RX center frequency (Hz)
FS=${2:-2000000}        # sample rate (Hz)
N=${3:-262144}          # number of samples to capture
OUT=${4:-/tmp/cap.iq}   # output file (int16 I/Q interleaved)

# Configure RX (best-effort; adjust channel names if your build differs).
iio_attr -q -c ad9361-phy altvoltage0 frequency "$FC"       2>/dev/null
iio_attr -q -c ad9361-phy voltage0 sampling_frequency "$FS" 2>/dev/null

T0=$(date +%s.%N)
iio_readdev -b "$N" -s "$N" cf-ad9361-lpc > "$OUT" 2>/dev/null
T1=$(date +%s.%N)

echo "center_freq : $FC Hz"
echo "sample_rate : $FS Hz"
echo "samples     : $N"
echo "output      : $OUT ($(wc -c < "$OUT") bytes, int16 I/Q interleaved)"
echo "GPS ts start: $T0"
echo "GPS ts end  : $T1   <- chrony/PPS-disciplined CLOCK_REALTIME"
echo
echo "clock discipline (want Leap: Normal and Reference ID: ...(PPS)):"
chronyc tracking 2>/dev/null | grep -E 'Reference ID|Stratum|Leap'
