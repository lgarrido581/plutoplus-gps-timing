"""Split a Zynq-7000 BOOT.bin into its partitions.

Usage: split_boot.py <BOOT.bin> <out dir>
Writes fsbl.elf (the FSBL wrapped as a one-segment ARM ELF at 0x0, so bootgen
takes it as [bootloader]), u-boot.bin (the partition loaded at 0x04000000) and
bitstream.bin (the PL partition, as stored).
"""
import struct
import sys
from pathlib import Path

img = Path(sys.argv[1]).read_bytes()
out = Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)


def word(off):
    return struct.unpack_from("<I", img, off)[0]


def elf32(code, addr):
    """Minimal ARM EXEC ELF: one PT_LOAD segment of `code` at `addr`."""
    phoff, data = 52, 0x100
    hdr = b"\x7fELF" + bytes([1, 1, 1, 0]) + bytes(8)
    hdr += struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, addr, phoff, 0, 0x05000000,
                       52, 32, 1, 40, 0, 0)
    ph = struct.pack("<8I", 1, data, addr, addr, len(code), len(code), 7, 4)
    return (hdr + ph).ljust(data, b"\0") + code


table = word(0x9C)
found = {}
for i in range(8):
    h = struct.unpack_from("<16I", img, table + 64 * i)
    total, load, exec_, offset, attr = h[2] * 4, h[3], h[4], h[5] * 4, h[6]
    if total == 0:
        break
    data = img[offset:offset + h[1] * 4]
    assert len(data) == h[1] * 4, f"partition {i} truncated"
    dest_pl = (attr >> 4) & 0x7 == 2
    if i == 0:
        (out / "fsbl.elf").write_bytes(elf32(data, load))
        found["fsbl"] = len(data)
    elif dest_pl:
        (out / "bitstream.bin").write_bytes(data)
        found["bitstream"] = len(data)
    elif load == 0x04000000 and exec_ == 0x04000000:
        (out / "u-boot.bin").write_bytes(data)
        found["u-boot"] = len(data)
for name in ("fsbl", "u-boot"):
    if name not in found:
        sys.exit(f"split_boot: no {name} partition in {sys.argv[1]}")
print("  " + ", ".join(f"{k} {v} bytes" for k, v in found.items()))
