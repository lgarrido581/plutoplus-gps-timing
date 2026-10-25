#!/usr/bin/env python3
"""Receiver for the iq_stream prototype: PULL the Pluto's stream into a RAM ring and check it.

Checks per block: sequence and sample-index continuity, DMA overflow, lag (how far the
delivered stream trails the hardware). Per PPS marker: the GPS second advances by one and
the marker lands ~fs samples after the previous one (the sample clock's ppm vs GPS).
Usage: stream_rx.py [bind] [ring_seconds] [idle_timeout_s]
"""
import json
import sys
import time

import numpy as np
import zmq

bind = sys.argv[1] if len(sys.argv) > 1 else "tcp://*:5563"
ring_s = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
idle = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0

sock = zmq.Context.instance().socket(zmq.PULL)
sock.setsockopt(zmq.RCVHWM, 64)
sock.setsockopt(zmq.RCVTIMEO, 120_000)        # wait for the stream to start...
sock.bind(bind)
print(f"listening on {bind}, ring {ring_s:.0f} s", flush=True)

ring = None
ring_pos = 0
n_blocks = n_samples = 0
seq_gaps = idx_gaps = ovf_blocks = 0
max_lag = 0.0
markers = []                       # (pps_seq, sample index, gps second)
t_first = t_last = None
cpu0 = time.process_time()
next_i0 = None
fs = fc = t0_ns = None
last_print = time.time()
while True:
    try:
        hdr_b, data = sock.recv_multipart(copy=False)
    except zmq.Again:
        break
    now = time.time()
    h = json.loads(bytes(hdr_b.buffer))
    buf = data.buffer
    if ring is None:
        sock.setsockopt(zmq.RCVTIMEO, int(idle * 1000))  # ...then end on silence
        fs, fc, t0_ns = h["fs"], h["fc"], h["t0_ns"]
        ring = np.empty(int(ring_s * fs) * 4, dtype=np.uint8)
        t_first = now
        print(f"stream: {fs / 1e6:.3f} MS/s at {fc / 1e6:.3f} MHz, sample 0 at GPS "
              f"{t0_ns / 1e9:.9f}, blocks of {h['n']} samples", flush=True)
    if h["seq"] != n_blocks:
        seq_gaps += 1
    if next_i0 is not None and h["i0"] != next_i0:
        idx_gaps += 1
    next_i0 = h["i0"] + h["n"]
    ovf_blocks += bool(h["ovf"])
    max_lag = max(max_lag, h["lag"])
    if h["pps"]:
        markers.append(tuple(h["pps"]))
    nb = len(buf)
    end = ring_pos + nb
    if end <= len(ring):
        ring[ring_pos:end] = np.frombuffer(buf, dtype=np.uint8)
    else:
        k = len(ring) - ring_pos
        ring[ring_pos:] = np.frombuffer(buf, dtype=np.uint8, count=k)
        ring[:nb - k] = np.frombuffer(buf, dtype=np.uint8, offset=k)
    ring_pos = end % len(ring)
    n_blocks += 1
    n_samples += h["n"]
    t_last = now
    if now - last_print >= 5.0:
        last_print = now
        print(f"  {n_samples / fs:6.1f} s of IQ, {n_blocks} blocks, lag max {max_lag:.0f}, "
              f"ovf {ovf_blocks}, gaps seq/idx {seq_gaps}/{idx_gaps}", flush=True)

if ring is None:
    sys.exit("no stream received")
dt = max(t_last - t_first, 1e-9)
cpu = time.process_time() - cpu0
print(f"done: {n_samples / fs:.1f} s of IQ ({n_samples * 4 / 1e6:.0f} MB) in {dt:.1f} s, "
      f"{n_samples * 4 / dt / 1e6:.1f} MB/s, receiver CPU {cpu / dt * 100:.0f}% of one core")
print(f"continuity: {seq_gaps} seq gaps, {idx_gaps} index gaps, {ovf_blocks} DMA-overflow "
      f"blocks, max lag {max_lag:.0f} samples ({max_lag / fs * 1e3:.1f} ms)")
if len(markers) >= 2:
    secs = np.array([m[2] for m in markers], dtype=float)
    idx = np.array([m[1] for m in markers], dtype=float)
    d_sec, d_idx = np.diff(secs), np.diff(idx)
    ppm = (d_idx / (d_sec * fs) - 1) * 1e6
    print(f"PPS markers: {len(markers)}, GPS seconds {'consecutive' if np.all(d_sec == 1) else 'NOT consecutive'}, "
          f"samples/s {np.mean(d_idx / d_sec):,.1f} (clock {np.mean(ppm):+.2f} ppm, "
          f"spread {np.ptp(ppm):.2f} ppm), first marker {markers[0][1]:.1f} samples "
          f"= {markers[0][1] / fs * 1e3:.3f} ms after sample 0")
iq = ring.view("<i2").astype(np.float32)
print(f"ring rms {np.sqrt(np.mean(iq ** 2)):.1f} counts, zero samples "
      f"{np.mean(iq == 0) * 100:.3f}%")
