#!/usr/bin/env python3
"""Capture an IQ block from a Pluto and attach + print a timestamp.

IMPORTANT: the Pluto's IQ stream has NO hardware-embedded per-sample timestamp.
The samples are raw I/Q. This attaches a SOFTWARE timestamp (CLOCK_REALTIME) at
buffer-arrival time and shows it alongside the data, to verify the capture +
timestamp path works.

Caveats for TDOA:
  * Run on a host PC: the timestamp is the HOST's wall clock, NOT the Pluto's GPS
    clock. For GPS-disciplined time, run the on-Pluto shell script
    (capture_gps_timestamped.sh), or NTP-sync this host to the Pluto's chrony.
  * The timestamp is buffer-ARRIVAL time over USB (ms-level jitter + latency), so
    it is good for coarse capture windows, NOT fine TDOA. Fine alignment needs a
    PPS marker injected into RX or a shared reference signal (see tdoa/README.md).

Requires: pip install pyadi-iio numpy
Usage:    python capture_timestamp.py [uri]
          e.g.  python capture_timestamp.py ip:pluto.local
                python capture_timestamp.py usb:1.5.5
"""
import sys
import time
import datetime
import numpy as np
import adi

URI = sys.argv[1] if len(sys.argv) > 1 else "ip:pluto.local"
FS = 2_000_000      # sample rate (Hz)
FC = 100_000_000    # RX center frequency (Hz)
N = 65_536          # samples per capture

sdr = adi.Pluto(URI)
sdr.sample_rate = int(FS)
sdr.rx_lo = int(FC)
sdr.rx_rf_bandwidth = int(FS)
sdr.rx_buffer_size = N
sdr.gain_control_mode_chan0 = "slow_attack"

# Flush the USB pipeline so we time a steady-state buffer.
for _ in range(3):
    sdr.rx()

t0 = time.time_ns()
iq = sdr.rx()            # blocks until N samples have arrived
t1 = time.time_ns()

dur = N / FS
t1_s = t1 / 1e9
iso = datetime.datetime.utcfromtimestamp(t1_s).isoformat()

print(f"uri               : {URI}")
print(f"samples           : {len(iq)}")
print(f"sample_rate       : {FS} Hz")
print(f"buffer duration   : {dur * 1e3:.3f} ms")
print(f"wall capture time : {(t1 - t0) / 1e6:.3f} ms (includes USB transfer)")
print(f"timestamp (epoch) : {t1_s:.9f}")
print(f"timestamp (UTC)   : {iso}Z   [HOST clock unless NTP-synced to the Pluto]")
print(f"~first-sample ts  : {t1_s - dur:.9f}  (buffer_end - duration; ignores USB latency)")
print(f"first 5 IQ        : {iq[:5]}")
print(f"mean power        : {10 * np.log10(np.mean(np.abs(iq) ** 2) + 1e-9):.1f} dBFS")

# Save the capture with a sidecar timestamp file (one capture = IQ + its time).
np.save("capture.npy", iq.astype(np.complex64))
with open("capture.timestamp", "w") as f:
    f.write(f"{t1_s:.9f}\n")
print("saved: capture.npy + capture.timestamp")
