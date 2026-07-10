#!/usr/bin/env python3
"""Backup and flash LibreSDR QSPI bootloader/env partitions over SSH.

This is intentionally separate from flash_libresdr_qspi.py because it writes
boot-critical partitions:

  mtd0 qspi-fsbl-uboot  <- output/libresdr-qspi/BOOT-qspi.bin
  mtd1 qspi-uboot-env   <- output/libresdr-qspi/uboot-env.bin

It does not write the firmware/FIT partition. Use flash_libresdr_qspi.py for
output/libre.frm after this step.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import time
from datetime import datetime
from pathlib import Path
from typing import Any


EXPECTED = {
    "/dev/mtd0": ("qspi-fsbl-uboot", 0x100000),
    "/dev/mtd1": ("qspi-uboot-env", 0x20000),
}
REMOTE_BOOT = "/tmp/_libresdr_BOOT_qspi.bin"
REMOTE_ENV = "/tmp/_libresdr_uboot_env.bin"


def connect(host: str, password: str, timeout: int = 15) -> Any:
    try:
        import paramiko
    except ModuleNotFoundError as exc:
        raise RuntimeError("missing dependency: run `python -m pip install paramiko`") from exc

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        host,
        username="root",
        password=password,
        timeout=timeout,
        look_for_keys=False,
        allow_agent=False,
    )
    return client


def run(client: Any, cmd: str, timeout: int = 300) -> tuple[int, str]:
    _stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = (stdout.read() + stderr.read()).decode(errors="replace").replace("\x00", "")
    return stdout.channel.recv_exit_status(), out


def checked_run(client: Any, cmd: str, timeout: int = 300) -> str:
    code, out = run(client, cmd, timeout)
    if code != 0:
        raise RuntimeError(f"remote command failed ({code}): {cmd}\n{out}")
    return out


def parse_proc_mtd(text: str) -> dict[str, dict[str, object]]:
    parts: dict[str, dict[str, object]] = {}
    for line in text.splitlines():
        match = re.match(r"^(mtd\d+):\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+\"([^\"]+)\"", line)
        if not match:
            continue
        dev, size_hex, erase_hex, name = match.groups()
        parts[f"/dev/{dev}"] = {
            "size": int(size_hex, 16),
            "erase": int(erase_hex, 16),
            "name": name,
        }
    return parts


def validate_layout(parts: dict[str, dict[str, object]]) -> None:
    for dev, (expected_name, expected_size) in EXPECTED.items():
        if dev not in parts:
            raise RuntimeError(f"{dev} missing from /proc/mtd")
        got = parts[dev]
        if got["name"] != expected_name:
            raise RuntimeError(f"{dev} is named {got['name']!r}, expected {expected_name!r}")
        if got["size"] != expected_size:
            raise RuntimeError(f"{dev} size is 0x{got['size']:x}, expected 0x{expected_size:x}")


def transfer(client: Any, local: Path, remote: str) -> str:
    data = local.read_bytes()
    stdin, stdout, stderr = client.exec_command(f"cat > {remote}")
    stdin.write(data)
    stdin.channel.shutdown_write()
    stdout.read()
    status = stdout.channel.recv_exit_status()
    if status != 0:
        raise RuntimeError(stderr.read().decode(errors="replace"))
    local_md5 = hashlib.md5(data).hexdigest()
    remote_md5 = checked_run(client, f"md5sum {remote}").split()[0]
    if remote_md5 != local_md5:
        raise RuntimeError(f"md5 mismatch for {local}: board {remote_md5} != host {local_md5}")
    return local_md5


def backup_partition(client: Any, dev: str, outdir: Path) -> Path:
    name = Path(dev).name
    out = outdir / f"{name}.bin"
    _stdin, stdout, stderr = client.exec_command(f"cat {dev}", timeout=120)
    data = stdout.read()
    err = stderr.read().decode(errors="replace")
    status = stdout.channel.recv_exit_status()
    if status != 0:
        raise RuntimeError(f"backup failed for {dev}: {err}")
    out.write_bytes(data)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", required=True, help="LibreSDR IP/hostname reachable by SSH")
    parser.add_argument("--password", default="analog", help="root SSH password")
    parser.add_argument("--boot", default="output/libresdr-qspi/BOOT-qspi.bin")
    parser.add_argument("--env", default="output/libresdr-qspi/uboot-env.bin")
    parser.add_argument("--backup-dir", default="")
    parser.add_argument("--flash", action="store_true", help="actually write mtd0/mtd1 after backup")
    parser.add_argument("--reboot", action="store_true", help="reboot after flashing")
    parser.add_argument("--force-board", action="store_true", help="allow missing /etc/gps-timing-board")
    parser.add_argument(
        "--i-understand-this-writes-bootloader",
        action="store_true",
        help="required with --flash",
    )
    args = parser.parse_args()

    boot = Path(args.boot)
    env = Path(args.env)
    if not boot.is_file():
        raise SystemExit(f"[!] missing boot image: {boot}")
    if not env.is_file():
        raise SystemExit(f"[!] missing env image: {env}")
    if boot.stat().st_size > EXPECTED["/dev/mtd0"][1]:
        raise SystemExit("[!] boot image does not fit /dev/mtd0")
    if env.stat().st_size != EXPECTED["/dev/mtd1"][1]:
        raise SystemExit("[!] env image must be exactly 0x20000 bytes")
    if args.flash and not args.i_understand_this_writes_bootloader:
        raise SystemExit("[!] refusing bootloader/env write without --i-understand-this-writes-bootloader")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_dir = Path(args.backup_dir or f"output/libresdr-qspi-backup-{stamp}")
    backup_dir.mkdir(parents=True, exist_ok=True)

    client = connect(args.host, args.password)
    try:
        print(f"[*] connected: {checked_run(client, 'uptime').strip()}")
        ident = checked_run(client, "cat /etc/gps-timing-board 2>/dev/null || true").strip()
        if "BOARD=libresdr" not in ident and not args.force_board:
            raise RuntimeError("target is not this repo's LibreSDR image; boot the validated SD image or use --force-board")
        print(f"[*] board identity: {ident or '(missing; forced)'}")

        parts = parse_proc_mtd(checked_run(client, "cat /proc/mtd"))
        validate_layout(parts)
        print("[*] QSPI layout matches expected LibreSDR/ADI layout")

        manifest = []
        for dev in ("/dev/mtd0", "/dev/mtd1", "/dev/mtd2"):
            out = backup_partition(client, dev, backup_dir)
            sha = hashlib.sha256(out.read_bytes()).hexdigest()
            manifest.append(f"{sha}  {out.name}")
            print(f"[*] backed up {dev} -> {out} ({out.stat().st_size} bytes)")
        (backup_dir / "SHA256SUMS.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")

        if not args.flash:
            print("[*] backup complete; not flashing because --flash was not passed")
            return 0

        boot_md5 = transfer(client, boot, REMOTE_BOOT)
        env_md5 = transfer(client, env, REMOTE_ENV)
        print(f"[*] transferred boot md5={boot_md5}")
        print(f"[*] transferred env  md5={env_md5}")

        checked_run(client, "flash_unlock /dev/mtd0 2>/dev/null || true")
        checked_run(client, "flash_unlock /dev/mtd1 2>/dev/null || true")
        print("[*] flashing /dev/mtd0 qspi-fsbl-uboot ...")
        out0 = checked_run(client, f"flashcp -v {REMOTE_BOOT} /dev/mtd0; echo FLASH0=$?", timeout=180)
        if "FLASH0=0" not in out0:
            raise RuntimeError(out0)
        print("[*] flashing /dev/mtd1 qspi-uboot-env ...")
        out1 = checked_run(client, f"flashcp -v {REMOTE_ENV} /dev/mtd1; echo FLASH1=$?", timeout=180)
        if "FLASH1=0" not in out1:
            raise RuntimeError(out1)
        checked_run(client, f"rm -f {REMOTE_BOOT} {REMOTE_ENV}")
        print("[*] bootloader/env flash complete")

        if args.reboot:
            print("[*] rebooting...")
            try:
                client.exec_command("sync; (sleep 1; /sbin/reboot) &", timeout=5)
            except Exception:
                pass
    finally:
        client.close()

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit("\n[!] interrupted")
    except Exception as exc:
        raise SystemExit(f"[!] {exc}")
