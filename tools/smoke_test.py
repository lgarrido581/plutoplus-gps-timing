#!/usr/bin/env python3
"""
smoke_test.py - per-board hardware release gate. Run against a FRESHLY FLASHED board
before tagging a release. Exits 0 only if every check passes.

It asserts the things static analysis + compilation can't: that on THIS board, with
THIS firmware, the timing is live AND an actual GPS-anchored capture succeeds. The
capture check is the one that would have caught the v2.0 `configure_tdd` regression
(which compiled clean and only failed at runtime, on Pluto+ but not LibreSDR) -- so
run this on EVERY supported board.

Requires: paramiko, pyzmq  (pip install paramiko pyzmq).

  python tools/smoke_test.py --host 192.168.50.30 --board plutoplus
  python tools/smoke_test.py --host <ip> --board libresdr --freq 94700000 --rate 2000000
"""
import argparse, json, math, sys, time

try:
    import paramiko, zmq
except ImportError as e:
    sys.exit(f"need paramiko + pyzmq: pip install paramiko pyzmq  ({e})")

results = []  # (name, ok, detail)
def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{(' -- ' + detail) if detail else ''}")
    return ok

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--board", choices=["plutoplus", "libresdr"], default="plutoplus")
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="analog")
    ap.add_argument("--freq", type=int, default=94700000)
    ap.add_argument("--rate", type=int, default=2000000)
    ap.add_argument("--samples", type=int, default=65536)
    ap.add_argument("--no-capture", action="store_true", help="skip the ctl capture check")
    args = ap.parse_args()
    print(f"=== smoke_test: {args.board} @ {args.host} ===")

    # --- SSH: board back, timing hardware live ---
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(args.host, username=args.user, password=args.password, timeout=15)
    except Exception as e:
        check("ssh connect", False, str(e)); return summarize()
    def sh(cmd, tmo=15):
        _, o, e = c.exec_command(cmd, timeout=tmo)
        return (o.read().decode(errors="replace") + e.read().decode(errors="replace")).strip()

    check("pps_present", sh("devmem 0x7C460008 32").strip() == "0x00000001",
          "STATUS bit0")
    p0 = sh("devmem 0x7C460018 32"); time.sleep(2); p1 = sh("devmem 0x7C460018 32")
    check("pps_advancing", p0 != p1, f"{p0}->{p1}")
    check("xo_correct locked", "locked" in sh("tail -5 /var/log/xocorrect.log 2>/dev/null"),
          "xocorrect.log")
    check("pluto_zmqd up", "pluto_zmqd" in sh("ps 2>/dev/null | grep '[p]luto_zmqd'"))
    ctld_up = "pluto_ctld" in sh("ps 2>/dev/null | grep '[p]luto_ctld'")
    check("pluto_ctld up", ctld_up)
    c.close()

    ctx = zmq.Context()
    # --- telemetry: RX DMA health ---
    try:
        s = ctx.socket(zmq.REQ); s.setsockopt(zmq.RCVTIMEO, 4000); s.setsockopt(zmq.LINGER, 0)
        s.connect(f"tcp://{args.host}:5561"); s.send_string("dma")
        dma = json.loads(s.recv()).get("dma", {}); s.close()
        check("dma.rx_ok", dma.get("rx_ok") is True, f"last_error={dma.get('last_error')}")
    except Exception as e:
        check("dma.rx_ok", False, str(e))

    # --- THE key check: an actual GPS-anchored capture must SUCCEED (2 frames) ---
    if not args.no_capture and ctld_up:
        try:
            s = ctx.socket(zmq.REQ); s.setsockopt(zmq.RCVTIMEO, 15000); s.setsockopt(zmq.LINGER, 0)
            s.connect(f"tcp://{args.host}:5562")
            t0 = math.ceil(time.time()) + 3           # agreed future PPS edge
            req = {"op": "capture", "freq_hz": args.freq, "sample_rate_hz": args.rate,
                   "samples": args.samples, "require_gps": True, "tdd_sync": True,
                   "t0_gps": t0, "offset_samples": 0, "node_id": "smoke"}
            s.send_string(json.dumps(req))
            frames = s.recv_multipart(); s.close()
            # 2 frames = success [meta, iq]; 1 frame = {"error":...} (the v2.0 bug path)
            if len(frames) == 2:
                meta = json.loads(frames[0]); cap = meta.get("captures", [{}])[0]
                degraded = meta.get("global", {}).get("timing:health", {}).get("degraded")
                method = cap.get("gpsanchor:method", "?")
                iq_ok = len(frames[1]) == args.samples * 4      # ci16_le = 4 bytes/sample
                check("ctl capture (tdd_sync)", iq_ok and degraded is False,
                      f"method={method} degraded={degraded} iq={len(frames[1])}B")
            else:
                err = ""
                try: err = json.loads(frames[0]).get("error", "")
                except Exception: pass
                check("ctl capture (tdd_sync)", False,
                      f"got {len(frames)} frame(s) (error='{err}') -- capture refused/failed")
        except Exception as e:
            check("ctl capture (tdd_sync)", False, str(e))
    elif not ctld_up:
        check("ctl capture (tdd_sync)", False, "pluto_ctld not running")
    ctx.term()
    return summarize()

def summarize():
    ok = all(r[1] for r in results)
    print(f"\n=== {'SMOKE PASS' if ok else 'SMOKE FAIL'} "
          f"({sum(r[1] for r in results)}/{len(results)} checks) ===")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
