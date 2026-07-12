#!/usr/bin/env python3
"""Flash a Pluto+ firmware .frm over the network (SSH), safely and repeatably.

The flash itself is delegated to the board's own **/sbin/update_frm.sh** -- the
same updater the USB mass-storage "drop pluto.frm + eject" path runs. That matters
because a raw `flashcp` to mtd3 is NOT sufficient: U-Boot reads exactly **`fit_size`
bytes** of the FIT from QSPI at boot, and update_frm.sh does `fw_setenv fit_size`
to match the new image. A `flashcp` that leaves `fit_size` stale will make U-Boot
load a TRUNCATED FIT when the new image is larger than the old `fit_size` -> the
board won't boot. (This bit us on v2.0.1: a 700 KB size change + a stale `fit_size`.)

Only mtd3 (`qspi-linux`, the FIT) is written; the FSBL/u-boot (mtd0) and env (mtd1)
are never touched, so DFU recovery (`device_reboot sf` + dfu-util) survives even an
interrupted flash. See RECOVERY.md.

This wrapper adds, around update_frm.sh:
  * a raw binary transfer of the .frm,
  * an md5 check ON THE BOARD before flashing (aborts on a corrupt transfer),
  * a post-flash assertion that `fit_size` now equals the new FIT.itb size,
  * reboot + a health probe (PPS live, pluto_zmqd RX-DMA OK).

Requires: paramiko  (pip install paramiko).

Usage:
    python flash_frm.py output/pluto.frm                 # default host pluto.local
    python flash_frm.py output/pluto.frm --host 192.168.50.30
    python flash_frm.py output/pluto.frm --no-reboot     # flash but don't reboot

Safety: ABORTS if the on-board md5 mismatches, if update_frm.sh does not print
"Done", or if `fit_size` does not match the new image afterward.
"""
import argparse
import hashlib
import sys
import time

import paramiko

REMOTE = "/tmp/_flash.frm"   # must end in .frm -- update_frm.sh checks the extension
TRAILER = 33                 # .frm = FIT.itb + 33-byte md5 trailer; U-Boot boots the FIT.itb


def connect(host, timeout=15):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username="root", password="analog", timeout=timeout,
              look_for_keys=False, allow_agent=False)
    return c


def run(c, cmd, timeout=300):
    _in, out, err = c.exec_command(cmd, timeout=timeout)
    return (out.read() + err.read()).decode(errors="replace").replace("\x00", "")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frm", help="path to the .frm to flash (e.g. output/pluto.frm)")
    ap.add_argument("--host", default="pluto.local",
                    help="Pluto address (default pluto.local; also try 192.168.50.30)")
    ap.add_argument("--no-reboot", action="store_true", help="flash but do not reboot")
    args = ap.parse_args()

    data = open(args.frm, "rb").read()
    local_md5 = hashlib.md5(data).hexdigest()
    # The FIT.itb is the .frm minus its 33-byte md5 trailer; update_frm.sh writes
    # that stripped image and sets fit_size to its length (uppercase hex, no 0x).
    fit_len = len(data) - TRAILER
    trailer = data[-TRAILER:].decode(errors="replace").strip()
    fit_md5 = hashlib.md5(data[:fit_len]).hexdigest()
    want_fit_size = format(fit_len, "X")
    print(f"[*] {args.frm}: {len(data)} bytes, md5={local_md5}")
    print(f"[*] FIT.itb={fit_len} bytes -> expected fit_size=0x{want_fit_size}")
    if trailer != fit_md5:
        sys.exit(f"[!] .frm trailer md5 ({trailer}) != FIT.itb md5 ({fit_md5}) -- the "
                 f".frm is malformed; update_frm.sh would reject it. ABORTING.")

    c = connect(args.host)
    print(f"[*] connected to {args.host} ({run(c, 'uptime').strip()})")
    if "update_frm.sh" not in run(c, "command -v update_frm.sh /sbin/update_frm.sh"):
        sys.exit("[!] /sbin/update_frm.sh not found on the board -- refusing to hand-roll "
                 "a flashcp (it would not set fit_size and could brick on a size change).")

    # 1. raw binary transfer (SSH is binary-safe; far faster than xxd hex)
    t = time.time()
    sin, sout, _ = c.exec_command(f"cat > {REMOTE}")
    sin.write(data); sin.channel.shutdown_write(); sout.read()
    print(f"[*] transferred in {time.time()-t:.1f}s")

    # 2. VERIFY md5 on the board BEFORE flashing -- abort on a corrupt transfer
    remote_md5 = run(c, f"md5sum {REMOTE}").split()[0]
    if remote_md5 != local_md5:
        sys.exit(f"[!] md5 MISMATCH (board {remote_md5} != local {local_md5}) -- ABORTING")
    print("[*] on-board md5 matches -- safe to flash")

    # 3. flash via the board's own updater: it md5-checks the trailer, strips it,
    #    dd's the FIT.itb to mtdblock3, AND runs `fw_setenv fit_size` so U-Boot reads
    #    the right length. This is the step a bare flashcp gets wrong.
    fit_before = run(c, "fw_printenv fit_size").strip()
    print(f"[*] flashing via update_frm.sh (was {fit_before})...")
    out = run(c, f"/sbin/update_frm.sh {REMOTE}; echo RC=$?")
    tail = [l for l in out.replace("\r", "\n").splitlines() if l.strip()][-4:]
    print("    " + "\n    ".join(tail))
    if "Done" not in out:
        sys.exit("[!] update_frm.sh did NOT print 'Done' (checksum/magic/write failure) -- "
                 "do NOT reboot; the old firmware is still in flash. Investigate.")

    # 4. assert fit_size now matches the new image -- the anti-brick invariant
    fit_after = run(c, "fw_printenv fit_size").strip()  # e.g. "fit_size=F8FB53"
    got = fit_after.split("=", 1)[-1].strip()
    if got.upper() != want_fit_size.upper():
        sys.exit(f"[!] fit_size is {got}, expected {want_fit_size} -- U-Boot would load a "
                 f"WRONG-length FIT. Do NOT reboot; re-run update_frm.sh. ABORTING.")
    print(f"[*] flash OK: fit_size {fit_before} -> {fit_after} (matches new FIT)")
    run(c, f"rm -f {REMOTE}")

    if args.no_reboot:
        print("[*] --no-reboot: not rebooting. Reboot the board to boot the new firmware.")
        c.close(); return

    # 5. reboot + verify it came back, timing is live, RX-DMA telemetry is OK
    print("[*] rebooting...")
    try: c.exec_command("sync; (sleep 1; /sbin/reboot) &", timeout=5)
    except Exception: pass
    c.close()
    time.sleep(10)
    host = None
    for h in (args.host, "192.168.50.30", "pluto.local"):  # mDNS can be slow post-boot
        for _ in range(20):
            try: c = connect(h, timeout=6); host = h; break
            except Exception: time.sleep(4); c = None
        if c: break
    if not c:
        sys.exit("[!] board did not come back in time. Check power; it may be at a "
                 "different address. (FSBL/u-boot intact -> DFU recovery available.)")
    # Health: back up, timing hardware LIVE (PPS advancing), telemetry up. RX is NOT
    # probed with a free-running iio_readdev -- this design DMA-starts RX off the TDD
    # channel, so a bare read starves and false-alarms. Authoritative RX health is
    # pluto_zmqd's dma.rx_ok (below).
    print(f"[*] back up: {run(c, 'uptime').strip()}")
    present = run(c, "devmem 0x7C460008 32").strip()
    pps0 = run(c, "devmem 0x7C460018 32").strip()
    time.sleep(2)
    pps1 = run(c, "devmem 0x7C460018 32").strip()
    zmqd = run(c, "ps 2>/dev/null | grep -q '[p]luto_zmqd' && echo up || echo down").strip()
    print(f"[*] pps_present={present}  pps_advancing={pps0 != pps1} ({pps0}->{pps1})  "
          f"pluto_zmqd={zmqd}")
    c.close()

    # RX-DMA health via pluto_zmqd telemetry (authoritative for this DMA-start
    # capture path). Needs pyzmq on the host; degrades gracefully if absent.
    try:
        import zmq, json
        ctx = zmq.Context(); s = ctx.socket(zmq.REQ)
        s.setsockopt(zmq.RCVTIMEO, 4000); s.setsockopt(zmq.LINGER, 0)
        s.connect(f"tcp://{host}:5561"); s.send_string("dma")
        dma = json.loads(s.recv()).get("dma", {})
        ok = dma.get("rx_ok")
        print(f"[*] dma.rx_ok={ok}  last_error={dma.get('last_error')}  "
              f"({'OK' if ok else 'CHECK'})")
        s.close(); ctx.term()
    except Exception as e:
        print(f"[*] RX-DMA: query pluto_zmqd :5561 'dma' for rx_ok "
              f"(pyzmq unavailable: {type(e).__name__})")
    print("[*] done. For a release, now run: python tools/smoke_test.py --host "
          f"{host} --board plutoplus")


if __name__ == "__main__":
    main()
