#!/usr/bin/env python3
"""Update an SD-boot board's boot set over the network (SSH).

The Fishball7020 boots from its SD card, and Linux on the board sees that card
as /dev/mmcblk0p1 (FAT32), so an update is a file copy rather than a QSPI flash.
QSPI is never written. This does, in order:

  1. checks the local set against its SHA256SUMS,
  2. mounts the card and downloads every file on it to a local backup directory
     (md5-checked against the board),
  3. uploads the new files under temporary names and md5-checks each on the
     board; nothing on the card is replaced until all of them match,
  4. keeps the card's previous set in /prev on the card, renames the new files
     into place, syncs and unmounts,
  5. reboots and reports what came back (banner, link speed, IIO devices,
     pps_counter ID, chrony sources).

If the new set does not boot, take the card out and copy the backup directory
(or the card's /prev) back to its root. See docs/FISHBALL.md.

Requires: paramiko  (pip install paramiko).

Usage:
    python tools/flash_sd.py output/fishball-sd --host <addr>
    python tools/flash_sd.py output/fishball-sd --host <addr> --no-reboot
    python tools/flash_sd.py <backup dir> --host <addr>   # restore a backup
"""
import argparse
import hashlib
import os
import sys
import time

import paramiko

BOOT_FILES = ["BOOT.bin", "uImage", "uramdisk.image.gz", "devicetree.dtb", "uEnv.txt"]
DEV, MNT = "/dev/mmcblk0p1", "/mnt/sd"


def connect(host, timeout=15):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username="root", password="analog", timeout=timeout,
              look_for_keys=False, allow_agent=False)
    return c


def run(c, cmd, timeout=120):
    _in, out, err = c.exec_command(cmd, timeout=timeout)
    return (out.read() + err.read()).decode(errors="replace").replace("\x00", "")


def fetch(c, path):
    _in, out, _err = c.exec_command(f"cat '{path}'")
    return out.read()


def put(c, path, data):
    sin, sout, _ = c.exec_command(f"cat > '{path}'")
    sin.write(data); sin.channel.shutdown_write(); sout.read()


def remote_md5(c, path):
    return (run(c, f"md5sum '{path}'").split() or ["?"])[0]


def load_set(d):
    files = {n: open(os.path.join(d, n), "rb").read() for n in BOOT_FILES
             if os.path.isfile(os.path.join(d, n))}
    missing = [n for n in BOOT_FILES if n not in files]
    if missing:
        sys.exit(f"[!] {d} is missing {', '.join(missing)} -- not a complete boot set")
    sums = os.path.join(d, "SHA256SUMS")
    if os.path.isfile(sums):
        for line in open(sums):
            want, name = line.split()
            name = name.lstrip("*")
            if name in files and hashlib.sha256(files[name]).hexdigest() != want:
                sys.exit(f"[!] {name} does not match {sums} -- ABORTING")
        print(f"[*] {d}: matches SHA256SUMS")
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set_dir", help="boot set to install (output/<board>-sd or a backup)")
    ap.add_argument("--host", required=True, help="board address")
    ap.add_argument("--backup-dir",
                    help="where the card's current files are saved first "
                         "(default: <set_dir>-backups)")
    ap.add_argument("--no-reboot", action="store_true", help="install but do not reboot")
    args = ap.parse_args()

    new = load_set(args.set_dir)
    backup_root = args.backup_dir or os.path.normpath(args.set_dir) + "-backups"
    c = connect(args.host)
    print(f"[*] connected to {args.host} ({run(c, 'uptime').strip()})")

    if f" {MNT} " not in run(c, "cat /proc/mounts"):
        out = run(c, f"mkdir -p {MNT} && mount -t vfat {DEV} {MNT} && echo MOUNTED")
        if "MOUNTED" not in out:
            sys.exit(f"[!] could not mount {DEV}: {out.strip()}")
    try:
        # 1. back up what is on the card now, to the host
        stamp = time.strftime("%Y%m%d-%H%M%S")
        bdir = os.path.join(backup_root, stamp)
        os.makedirs(bdir)
        sums = []
        for n in BOOT_FILES + ["SHA256SUMS"]:
            if "yes" not in run(c, f"test -f '{MNT}/{n}' && echo yes"):
                continue
            data = fetch(c, f"{MNT}/{n}")
            if hashlib.md5(data).hexdigest() != remote_md5(c, f"{MNT}/{n}"):
                sys.exit(f"[!] backup of {n} does not match the card -- ABORTING, card unchanged")
            open(os.path.join(bdir, n), "wb").write(data)
            if n != "SHA256SUMS":
                sums.append(f"{hashlib.sha256(data).hexdigest()}  {n}\n")
        if sums and not os.path.isfile(os.path.join(bdir, "SHA256SUMS")):
            open(os.path.join(bdir, "SHA256SUMS"), "w").writelines(sums)
        print(f"[*] card backed up to {bdir}")

        # 2. upload under temporary names; verify all before touching the live set
        t = time.time()
        for n, data in new.items():
            put(c, f"{MNT}/{n}.new", data)
            if remote_md5(c, f"{MNT}/{n}.new") != hashlib.md5(data).hexdigest():
                run(c, f"rm -f {MNT}/*.new")
                sys.exit(f"[!] md5 mismatch on {n} after upload -- ABORTING, card unchanged")
        print(f"[*] uploaded and verified {len(new)} files in {time.time()-t:.1f}s")

        # 3. keep the previous set on the card, then swap the new one in
        cmd = [f"rm -rf {MNT}/prev", f"mkdir {MNT}/prev"]
        cmd += [f"if [ -f {MNT}/{n} ]; then cp {MNT}/{n} {MNT}/prev/{n}; fi" for n in BOOT_FILES]
        cmd += [f"mv {MNT}/{n}.new {MNT}/{n}" for n in new]
        sha = os.path.join(args.set_dir, "SHA256SUMS")
        run(c, " && ".join(cmd) + " && sync")
        if os.path.isfile(sha):
            put(c, f"{MNT}/SHA256SUMS", open(sha, "rb").read())
        bad = [n for n, d in new.items()
               if remote_md5(c, f"{MNT}/{n}") != hashlib.md5(d).hexdigest()]
        if bad:
            sys.exit(f"[!] {', '.join(bad)} wrong on the card after the swap -- do NOT reboot; "
                     f"restore from {bdir}")
        print("[*] new set in place (previous set kept in /prev on the card)")
    finally:
        run(c, f"sync; umount {MNT}")

    if args.no_reboot:
        print("[*] --no-reboot: reboot the board to boot the new set."); c.close(); return

    print("[*] rebooting...")
    try: c.exec_command("sync; (sleep 1; /sbin/reboot) &", timeout=5)
    except Exception: pass
    c.close()
    time.sleep(15)
    c = None
    for _ in range(30):
        try: c = connect(args.host, timeout=6); break
        except Exception: time.sleep(4)
    if not c:
        sys.exit("[!] board did not come back on the network. Check the FTDI console; "
                 f"to roll back, copy {bdir} to the card root.")
    print(f"[*] back up: {run(c, 'uptime').strip()}")
    print(run(c, "grep -m1 -i firmware /etc/motd; uname -r; "
                 "echo eth0 $(cat /sys/class/net/eth0/speed 2>/dev/null) Mb/s; "
                 "cat /sys/bus/iio/devices/*/name 2>/dev/null | tr '\\n' ' '; echo; "
                 "echo pps_counter_id=$(devmem 0x7C460000 32 2>/dev/null); "
                 "chronyc -n sources 2>/dev/null | tail -n +3").rstrip())
    c.close()


if __name__ == "__main__":
    main()
