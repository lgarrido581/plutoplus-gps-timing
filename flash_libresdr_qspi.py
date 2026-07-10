#!/usr/bin/env python3
"""Flash a validated LibreSDR .frm image to QSPI over SSH.

This is intentionally a second-stage workflow:

  1. boot the image from SD,
  2. run the LibreSDR hardware acceptance checks,
  3. then promote the same FIT firmware image to QSPI.

By default this script writes only the QSPI firmware/FIT partition. It does not
write the FSBL, U-Boot, U-Boot environment, or spare/NVM partitions.

Requires:
    pip install paramiko

Examples:
    python flash_libresdr_qspi.py --host 192.168.1.50 --yes
    python flash_libresdr_qspi.py output/libre.frm --host 192.168.1.50 --run-lvds-test --yes
    python flash_libresdr_qspi.py --host 192.168.1.50 --no-reboot --yes
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import time
from pathlib import Path
from typing import Any


REMOTE = "/tmp/_libresdr_flash.frm"
DEFAULT_FRM = Path("output/libre.frm")
EXPECTED_BOARD = "BOARD=libresdr"
UNSAFE_LIBRESDR_QSPI_HINTS = (
    "found w25q256, expected n25q256a",
    "failed to read ear reg",
)
FIRMWARE_PARTITION_NAMES = {
    "qspi-linux",
    "firmware",
    "qspi-firmware",
    "linux",
}
REFUSE_PARTITION_NAME_FRAGMENTS = (
    "boot",
    "fsbl",
    "uboot",
    "u-boot",
    "env",
    "nvm",
    "spare",
)


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


def parse_proc_mtd(text: str) -> list[dict[str, object]]:
    parts: list[dict[str, object]] = []
    for line in text.splitlines():
        match = re.match(r"^(mtd\d+):\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+\"([^\"]+)\"", line)
        if not match:
            continue
        dev, size_hex, erase_hex, name = match.groups()
        parts.append(
            {
                "dev": f"/dev/{dev}",
                "size": int(size_hex, 16),
                "erase": int(erase_hex, 16),
                "name": name,
            }
        )
    return parts


def choose_mtd(parts: list[dict[str, object]], image_size: int, override: str | None) -> str:
    if override:
        match = next((p for p in parts if p["dev"] == override), None)
        if match:
            name = str(match["name"]).lower()
            if any(fragment in name for fragment in REFUSE_PARTITION_NAME_FRAGMENTS):
                raise RuntimeError(f"refusing to flash protected-looking partition {override} ({match['name']})")
            if int(match["size"]) < image_size:
                raise RuntimeError(f"{override} is smaller than the image")
        return override

    candidates = [
        p for p in parts
        if str(p["name"]).lower() in FIRMWARE_PARTITION_NAMES and int(p["size"]) >= image_size
    ]
    if len(candidates) == 1:
        return str(candidates[0]["dev"])

    # ADI/Pluto-style fallback: firmware/FIT begins at QSPI offset 0x200000 and
    # is usually exposed as mtd3. Only accept it if the partition is large enough
    # and not named like bootloader/env/spare storage.
    mtd3 = next((p for p in parts if p["dev"] == "/dev/mtd3"), None)
    if mtd3 and int(mtd3["size"]) >= image_size:
        name = str(mtd3["name"]).lower()
        if not any(fragment in name for fragment in REFUSE_PARTITION_NAME_FRAGMENTS):
            return "/dev/mtd3"

    table = "\n".join(
        f"  {p['dev']} {p['size']:>10} bytes \"{p['name']}\"" for p in parts
    )
    raise RuntimeError(
        "could not identify a single safe firmware MTD partition. "
        "Pass --mtd /dev/mtdN after checking /proc/mtd.\n" + table
    )


def transfer(client: Any, data: bytes) -> float:
    start = time.time()
    stdin, stdout, stderr = client.exec_command(f"cat > {REMOTE}")
    stdin.write(data)
    stdin.channel.shutdown_write()
    stdout.read()
    err = stderr.read().decode(errors="replace")
    status = stdout.channel.recv_exit_status()
    if status != 0:
        raise RuntimeError(f"transfer failed ({status}): {err}")
    return time.time() - start


def board_identity(client: Any) -> str:
    _code, text = run(client, "cat /etc/gps-timing-board 2>/dev/null || true")
    return text.strip()


def post_reboot_verify(hosts: list[str], password: str) -> None:
    client: Any | None = None
    connected_host = ""
    for host in hosts:
        for _ in range(24):
            try:
                client = connect(host, password, timeout=6)
                connected_host = host
                break
            except Exception:
                time.sleep(5)
        if client:
            break

    if not client:
        raise RuntimeError(
            "board did not come back in time. Check its IP address or serial console. "
            "The script only wrote the firmware partition, so the bootloader should still be recoverable."
        )

    try:
        print(f"[*] reconnected to {connected_host}: {checked_run(client, 'uptime').strip()}")
        ident = board_identity(client)
        print(f"[*] board identity: {ident or '(missing)'}")

        checked_run(client, "iio_attr -d cf-ad9361-lpc sync_start_enable disarm >/dev/null 2>&1 || true")
        code, _ = run(
            client,
            "iio_readdev -b 8192 -s 8192 cf-ad9361-lpc voltage0 voltage1 >/tmp/_rx 2>/dev/null",
            timeout=15,
        )
        count = checked_run(client, "wc -c < /tmp/_rx 2>/dev/null || echo 0").strip()
        checked_run(client, "rm -f /tmp/_rx")
        pps = checked_run(client, "devmem 0x7C460008 32 2>/dev/null || true").strip()
        rx_status = "OK" if code == 0 and count == "32768" else "CHECK"
        print(f"[*] pps_present={pps or '(unreadable)'}  RX={count} bytes ({rx_status})")
    finally:
        client.close()


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "frm",
        nargs="?",
        default=str(DEFAULT_FRM),
        help="LibreSDR .frm image to flash (default: output/libre.frm)",
    )
    parser.add_argument("--host", required=True, help="LibreSDR IP/hostname reachable by SSH")
    parser.add_argument("--password", default="analog", help="root SSH password (default: analog)")
    parser.add_argument("--mtd", help="override firmware MTD device after checking /proc/mtd")
    parser.add_argument("--no-reboot", action="store_true", help="flash but do not reboot")
    parser.add_argument(
        "--run-lvds-test",
        action="store_true",
        help="run verify_lvds.sh before flashing; abort if it fails",
    )
    parser.add_argument(
        "--force-board",
        action="store_true",
        help="allow flashing if /etc/gps-timing-board is missing or not LibreSDR",
    )
    parser.add_argument(
        "--allow-linux-mtd-qspi",
        action="store_true",
        help=(
            "override the LibreSDR Linux-MTD QSPI safety check. Do not use this "
            "unless the running kernel/device tree has been validated to write "
            "the board's QSPI flash correctly."
        ),
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="required acknowledgement that QSPI will be written",
    )
    args = parser.parse_args()

    frm = Path(args.frm)
    if not frm.is_file():
        raise SystemExit(f"[!] firmware image not found: {frm}")
    data = frm.read_bytes()
    local_md5 = hashlib.md5(data).hexdigest()
    local_sha256 = hashlib.sha256(data).hexdigest()
    print(f"[*] {frm}: {len(data)} bytes")
    print(f"[*] md5={local_md5}")
    print(f"[*] sha256={local_sha256}")

    if not args.yes:
        raise SystemExit("[!] refusing to write QSPI without --yes")

    client = connect(args.host, args.password)
    try:
        print(f"[*] connected to {args.host}: {checked_run(client, 'uptime').strip()}")
        ident = board_identity(client)
        if EXPECTED_BOARD not in ident and not args.force_board:
            raise RuntimeError(
                f"refusing to flash because /etc/gps-timing-board is not LibreSDR:\n"
                f"{ident or '(missing)'}\n"
                "Boot the validated LibreSDR SD image first, or pass --force-board if you have "
                "verified the target manually."
            )
        print(f"[*] board identity: {ident or '(missing; forced)'}")

        mtd_text = checked_run(client, "cat /proc/mtd")
        parts = parse_proc_mtd(mtd_text)
        if not parts:
            raise RuntimeError("could not parse /proc/mtd")
        mtd = choose_mtd(parts, len(data), args.mtd)
        part = next((p for p in parts if p["dev"] == mtd), None)
        if part:
            print(f"[*] selected {mtd}: {part['size']} bytes \"{part['name']}\"")
        else:
            print(f"[*] selected override MTD: {mtd}")

        if EXPECTED_BOARD in ident and not args.allow_linux_mtd_qspi:
            _code, qspi_log = run(
                client,
                "dmesg | grep -E 'spi-nor|w25q256|n25q256|failed to read ear' || true",
            )
            if any(hint in qspi_log for hint in UNSAFE_LIBRESDR_QSPI_HINTS):
                raise RuntimeError(
                    "refusing the LibreSDR Linux-MTD QSPI write path because the "
                    "running kernel reports a suspicious SPI-NOR/device-tree "
                    "mismatch:\n"
                    f"{qspi_log.strip()}\n\n"
                    "Use U-Boot DFU for the firmware partition instead:\n"
                    "  1. boot with the LibreSDR DFU button held until Windows "
                    "shows VID_0456&PID_B674;\n"
                    "  2. run tools/flash-libresdr-qspi-firmware-dfu.ps1.\n\n"
                    "This guard exists because this mismatch was observed to "
                    "erase /dev/mtd3 successfully but corrupt data during Linux "
                    "MTD writes."
                )

        free = checked_run(client, "df -Pk /tmp | awk 'NR==2 {print $4}'").strip()
        try:
            if int(free) * 1024 < len(data):
                raise RuntimeError(f"/tmp has only {free} KiB free; need at least {len(data)} bytes")
        except ValueError:
            print("[!] warning: could not parse /tmp free space")

        if args.run_lvds_test:
            print("[*] running verify_lvds.sh before flashing...")
            code, out = run(client, "verify_lvds.sh", timeout=180)
            print(out.rstrip())
            if code != 0:
                raise RuntimeError("verify_lvds.sh failed; refusing to promote this image to QSPI")

        elapsed = transfer(client, data)
        print(f"[*] transferred to {REMOTE} in {elapsed:.1f}s")

        remote_md5 = checked_run(client, f"md5sum {REMOTE}").split()[0]
        if remote_md5 != local_md5:
            raise RuntimeError(f"md5 mismatch on board: {remote_md5} != {local_md5}")
        print("[*] on-board md5 matches")

        checked_run(client, f"flash_unlock {mtd} 2>/dev/null || true")
        print(f"[*] flashing {mtd} (erase + write + verify; do not power off)...")
        code, out = run(client, f"flashcp -v {REMOTE} {mtd}; echo FLASH_EXIT=$?", timeout=180)
        interesting = [line for line in out.replace("\r", "\n").splitlines() if line.strip()]
        if interesting:
            print("    " + "\n    ".join(interesting[-6:]))
        if code != 0 or "FLASH_EXIT=0" not in out:
            raise RuntimeError("flashcp did not report success; do not reboot until you inspect the board")
        checked_run(client, f"rm -f {REMOTE}")
        print("[*] flash OK")

        if args.no_reboot:
            print("[*] --no-reboot: leaving the board running. Reboot manually to boot QSPI.")
            return 0

        print("[*] rebooting...")
        try:
            client.exec_command("sync; (sleep 1; /sbin/reboot) &", timeout=5)
        except Exception:
            pass
    finally:
        client.close()

    time.sleep(10)
    post_reboot_verify([args.host], args.password)
    print("[*] done.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit("\n[!] interrupted")
    except Exception as exc:
        raise SystemExit(f"[!] {exc}")
