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

    # 4. reboot + verify it came back and RX works
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
    run(c, "iio_attr -d cf-ad9361-lpc sync_start_enable disarm >/dev/null 2>&1; rm -f /tmp/_rx")
    run(c, "iio_readdev -b 8192 -s 8192 cf-ad9361-lpc voltage0 voltage1 >/tmp/_rx 2>/dev/null", timeout=12)
    nb = run(c, "wc -c < /tmp/_rx").strip(); run(c, "rm -f /tmp/_rx")
    print(f"[*] back up: {run(c, 'uptime').strip()}")
    print(f"[*] pps_present={run(c, 'devmem 0x7C460008 32').strip()}  RX={nb} bytes "
          f"({'OK' if nb=='32768' else 'CHECK'})")
    c.close()
    print("[*] done.")


if __name__ == "__main__":
    main()
