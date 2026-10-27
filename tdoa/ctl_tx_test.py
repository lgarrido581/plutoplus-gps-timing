#!/usr/bin/env python3
"""pluto_ctld TX check: load a chirp CPI, stream RX to a receiver, start TX, look for the
TX_START / TX_HASH markers in the ring, stop.

    python3 tdoa/ctl_tx_test.py --ctl tcp://192.168.50.30:5562 \
        --connect tcp://192.168.50.20:5563 --ring /iq0 --seconds 10

The order is the one pluto_ctld asks for: tx_load (TX tuning would disturb a running RX
stream), stream_start at TX's rate, tx_start. Needs pyzmq and numpy; the ring check
needs iq-ring's Python package (iqring) and a receiver feeding --ring.
"""
import argparse
import json
import sys
import time

import numpy as np
import zmq


def fnv1a64(b: bytes) -> int:
    h = 1469598103934665603
    for x in b:
        h = ((h ^ x) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h


def chirp_cpi(rate: float, n_pri: int, n_sweeps: int, bw: float) -> bytes:
    """One CPI of an up-chirp FMCW waveform, ci16 I/Q at half scale."""
    t = np.arange(n_pri) / rate
    k = bw / (n_pri / rate)
    s = np.exp(1j * np.pi * (k * t * t - bw * t))
    iq = np.empty((n_pri, 2), dtype=np.int16)
    iq[:, 0] = np.round(s.real * 16384)
    iq[:, 1] = np.round(s.imag * 16384)
    return np.tile(iq, (n_sweeps, 1)).tobytes()


def ask(sock, req, payload=None):
    if payload is None:
        sock.send_string(json.dumps(req) if isinstance(req, dict) else req)
    else:
        sock.send_multipart([json.dumps(req).encode(), payload])
    return json.loads(sock.recv_multipart()[0])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ctl", default="tcp://192.168.50.30:5562")
    ap.add_argument("--connect", default="tcp://192.168.50.20:5563", help="the receiver, as the radio reaches it")
    ap.add_argument("--ring", default=None, help="iq-ring segment the receiver writes (e.g. /iq0)")
    ap.add_argument("--rate", type=float, default=4e6)
    ap.add_argument("--freq", type=float, default=2.4e9)
    ap.add_argument("--tx-gain", type=float, default=-30.0)
    ap.add_argument("--rx-gain", type=float, default=30.0)
    ap.add_argument("--n-pri", type=int, default=4000)
    ap.add_argument("--sweeps", type=int, default=64)
    ap.add_argument("--bw", type=float, default=1e6)
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--iqring", default="~/iq-ring/python", help="iq-ring's python/ directory")
    a = ap.parse_args()

    s = zmq.Context.instance().socket(zmq.REQ)
    s.setsockopt(zmq.RCVTIMEO, 30000)
    s.setsockopt(zmq.LINGER, 0)
    s.connect(a.ctl)
    caps = ask(s, "ping").get("caps", [])
    print("caps:", caps)
    if "tx" not in caps or "stream" not in caps:
        print("this pluto_ctld has no tx/stream ops")
        return 1
    payload = chirp_cpi(a.rate, a.n_pri, a.sweeps, a.bw)
    want_hash = fnv1a64(payload)
    want_len = a.n_pri * a.sweeps
    ok = True
    try:
        r = ask(s, {"op": "tx_load", "freq_hz": a.freq, "sample_rate_hz": a.rate,
                    "gain_db": a.tx_gain}, payload)
        print("tx_load:", r)
        if not r.get("ok"):
            return 1
        tx_hash = int(r["tx"]["hash"], 16)
        print(f"  hash {tx_hash:#018x} (expected {want_hash:#018x}) "
              f"{'ok' if tx_hash == want_hash else 'MISMATCH'}")
        ok &= tx_hash == want_hash
        r = ask(s, {"op": "stream_start", "connect": a.connect, "freq_hz": a.freq,
                    "sample_rate_hz": a.rate, "gain_db": a.rx_gain, "block_ms": 100})
        print("stream_start:", r.get("ok"), r.get("error", ""))
        if not r.get("ok"):
            return 1
        r = ask(s, {"op": "tx_start"})
        print("tx_start:", r)
        if not r.get("ok"):
            return 1
        time.sleep(a.seconds)
        print("tx_status:", ask(s, {"op": "tx_status"}))
        st = ask(s, {"op": "stream_status"})["stream"]
        print("stream:", {k: st[k] for k in ("state", "epochs", "blocks", "MBps", "ended", "ensm_was")})
        if a.ring:
            import os
            sys.path.insert(0, os.path.expanduser(a.iqring))
            from iqring import Ring, wire
            with Ring.open(a.ring) as ring:
                m = ring.markers()
                tx = m[m["kind"] == wire.M_TX_START]
                th = m[m["kind"] == wire.M_TX_HASH]
                print(f"ring {a.ring}: {len(tx)} TX_START, {len(th)} TX_HASH markers")
                for x in tx[-3:]:
                    print(f"  epoch {int(x['epoch'])} tick {int(x['tick'])} "
                          f"(sample {int(x['tick']) / ring.ticks_per_sample:.1f}) len {int(x['value'])}")
                ok &= len(tx) > 0 and all(int(x["value"]) == want_len for x in tx)
                ok &= len(th) > 0 and all((int(x["value"]) & 0xFFFFFFFFFFFFFFFF) == want_hash for x in th)
    finally:
        print("tx_stop:", ask(s, {"op": "tx_stop"}).get("ok"))
        print("stream_stop:", ask(s, {"op": "stream_stop"}).get("ok"))
    print("TX CHECK", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
