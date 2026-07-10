#!/usr/bin/env python3
"""Flash a Pluto+ firmware .frm over the network (SSH), safely and repeatably.

This is the same sequence we validated by hand: raw-transfer the .frm, verify its
md5 ON THE BOARD before touching flash, then flashcp it to the qspi-linux MTD and
reboot. Only the Linux/bitstream partition (mtd3) is written -- the FSBL/u-boot
(mtd0) and env (mtd1) are never touched, so DFU recovery (`device_reboot sf` +
dfu-util) is always available even if a flash is interrupted.

This is the underlying operation the USB mass-storage "drop pluto.frm + eject"
update performs internally (flashcp to the QSPI), just done over SSH.

Requires: paramiko  (pip install paramiko).

Usage:
    python flash_frm.py output/pluto.frm                 # default host pluto.local
    python flash_frm.py output/pluto.frm --host 192.168.50.30
    python flash_frm.py output/pluto.frm --no-reboot     # flash but don't reboot

Safety: the flash is ABORTED if the on-board md5 does not match the local file.
"""
import argparse
import hashlib
import sys
import time

import paramiko

MTD = "/dev/mtd3"            # qspi-linux (holds the FIT); FSBL/u-boot/env are untouched
REMOTE = "/tmp/_flash.frm"


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
    print(f"[*] {args.frm}: {len(data)} bytes, md5={local_md5}")

    c = connect(args.host)
    print(f"[*] connected to {args.host} ({run(c, 'uptime').strip()})")

    # 1. raw binary transfer (SSH is binary-safe; far faster than xxd hex)
    t = time.time()
    sin, sout, _ = c.exec_command(f"cat > {REMOTE}")
    sin.write(data); sin.channel.shutdown_write(); sout.read()
    print(f"[*] transferred in {time.time()-t:.1f}s")

    # 2. VERIFY md5 on the board BEFORE flashing -- abort on mismatch
    remote_md5 = run(c, f"md5sum {REMOTE}").split()[0]
    if remote_md5 != local_md5:
        sys.exit(f"[!] md5 MISMATCH (board {remote_md5} != local {local_md5}) -- ABORTING")
    print(f"[*] on-board md5 matches -- safe to flash")

    # 3. flashcp to mtd3 (erase + write + verify). flash_unlock may say "not
    #    supported"; that's fine -- flashcp still erases+writes.
    run(c, f"flash_unlock {MTD} 2>/dev/null")
    print(f"[*] flashing {MTD} (erase + write + verify, ~30-60s)...")
    out = run(c, f"flashcp -v {REMOTE} {MTD}; echo EXIT=$?")
    last = [l for l in out.replace("\r", "\n").splitlines() if l.strip()][-3:]
    print("    " + "\n    ".join(last))
    if "EXIT=0" not in out:
        sys.exit("[!] flashcp did NOT report success -- do NOT reboot; investigate")
    run(c, f"rm -f {REMOTE}")
    print("[*] flash OK (written + verified)")

    if args.no_reboot:
        print("[*] --no-reboot: not rebooting. Reboot the board to boot the new firmware.")
        c.close(); return

    # 4. reboot + verify it came back, timing is live, and RX-DMA telemetry is OK
    print("[*] rebooting...")
    try: c.exec_command("sync; (sleep 1; /sbin/reboot) &", timeout=5)
    except Exception: pass
    c.close()
    time.sleep(10)
    for host in (args.host, "192.168.50.30", "pluto.local"):  # mDNS can be slow post-boot
        for _ in range(20):
            try: c = connect(host, timeout=6); break
            except Exception: time.sleep(4); c = None
        if c: break
    if not c:
        sys.exit("[!] board did not come back in time. Check power; it may be at a "
                 "different address. (FSBL/u-boot intact -> DFU recovery available.)")
    # Health: board is back, timing hardware is LIVE (PPS advancing), and the
    # telemetry service is up. RX is intentionally NOT probed with a free-running
    # iio_readdev -- this design DMA-starts the RX buffer off the TDD channel, so a
    # bare read starves and false-alarms. The authoritative RX-DMA health is
    # pluto_zmqd's dma.rx_ok (below), which reflects the real capture path.
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
    print("[*] done.")


if __name__ == "__main__":
    main()
