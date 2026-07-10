#!/usr/bin/env python3
"""Build a non-redundant U-Boot environment image from a text env file."""
from __future__ import annotations

import argparse
import binascii
from collections import OrderedDict
from pathlib import Path


def parse_size(text: str) -> int:
    return int(text, 0)


def read_env(path: Path) -> OrderedDict[str, str]:
    env: OrderedDict[str, str] = OrderedDict()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"{path}: invalid environment line without '=': {raw!r}")
        key, value = line.split("=", 1)
        if not key:
            raise SystemExit(f"{path}: empty environment variable name")
        if key in env:
            del env[key]
        env[key] = value
    return env


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="text U-Boot environment")
    parser.add_argument("output", type=Path, help="binary environment image")
    parser.add_argument("--size", default="0x20000", type=parse_size, help="total image size")
    args = parser.parse_args()

    env = read_env(args.input)
    body = b"".join(f"{key}={value}".encode("utf-8") + b"\0" for key, value in env.items()) + b"\0"
    data_size = args.size - 4
    if len(body) > data_size:
        raise SystemExit(f"environment is {len(body)} bytes, exceeds data area {data_size} bytes")

    data = body + (b"\xff" * (data_size - len(body)))
    crc = binascii.crc32(data) & 0xFFFFFFFF
    image = crc.to_bytes(4, "little") + data
    args.output.write_bytes(image)
    print(f"Wrote {args.output} ({len(image)} bytes, crc=0x{crc:08x}, vars={len(env)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
