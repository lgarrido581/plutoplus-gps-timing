#!/usr/bin/env python3
"""ppsc - GPS pps_counter tool for the ADRV9009-ZU11EG (runs on the SOM as root).

  ppsc.py status                       registers, once
  ppsc.py watch [-n 60]                PPS_DELTA every second vs nominal (lock test)
  ppsc.py capture [-o OFFSET] [-n N]   one GPS-gated RX capture, stamped
  ppsc.py chrony [--socket PATH]       feed chrony a refclock from the FPGA counter

Registers are mapped from /dev/mem at 0x9C46_0000 (HDL 0x7C46_0000 behind
ADI's ZynqMP interconnect) with 32-bit accesses only: pps_counter ignores
byte strobes, so a byte-wide write would corrupt the neighbouring bytes.
See docs/ADRV9009_ZU11EG.md for the hardware set-up and the test plan.
"""
import argparse
import ctypes
import mmap
import os
import socket
import struct
import sys
import time

BASE = 0x9C460000
ID_MAGIC = 0x50505343                     # "PPSC"
REG = dict(ID=0x00, CTRL=0x04, STATUS=0x08, LIVE_COUNT=0x0C, PPS_COUNT=0x10,
           PPS_DELTA=0x14, PPS_SEQ=0x18, TDD_CTRL=0x1C, FRAME_LEN=0x20,
           RX_START=0x24, RX_STOP=0x28, FRAME_POS=0x34, FRAME_SEQ=0x38,
           LATCH_COUNT=0x3C, LATCH_SEQ=0x40)
TDD_GPS_WINDOW = 0x7                      # enable | pps_sync_en | drive_pins
NOMINAL_HZ = 245_760_000                  # core_clk_b, ADI's default profile
ARM_LEAD_S = 0.35                         # arm this long before the target PPS
TPL_START_TICKS = 2                       # util_ext_sync: first sample = latch + 2
RX_DEVICE = "axi-adrv9009-rx-hpc"


class PpsCounter:
    def __init__(self, base: int = BASE):
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self._mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        os.close(fd)
        self._r = (ctypes.c_uint32 * 0x400).from_buffer(self._mm)   # word access
        if self.rd("ID") != ID_MAGIC:
            sys.exit(f"no pps_counter at {base:#x} (ID {self.rd('ID'):#010x}); wrong bitstream?")

    def rd(self, name: str) -> int:
        return self._r[REG[name] >> 2]

    def wr(self, name: str, value: int) -> None:
        self._r[REG[name] >> 2] = value & 0xFFFFFFFF

    def wait_pps(self, timeout: float = 1.5) -> bool:
        """Return True just after the next PPS edge (PPS_SEQ changes)."""
        seq, t_end = self.rd("PPS_SEQ"), time.monotonic() + timeout
        while time.monotonic() < t_end:
            if self.rd("PPS_SEQ") != seq:
                return True
            time.sleep(0.002)
        return False

    def gps_window(self, frame_len: int, rx_start: int, rx_stop: int) -> None:
        self.wr("TDD_CTRL", 0)                 # registers cross clocks: disable first
        self.wr("FRAME_LEN", frame_len)
        self.wr("RX_START", rx_start)
        self.wr("RX_STOP", rx_stop)
        self.wr("TDD_CTRL", TDD_GPS_WINDOW)   # also switches the RX sync mux to GPS

    def release(self) -> None:
        self.wr("TDD_CTRL", 0)                 # mux back to SYSREF (ADI behaviour)


def s32(x: int) -> int:
    return x - (1 << 32) if x & 0x80000000 else x


def cmd_status(p: PpsCounter, a) -> None:
    for name in REG:
        v = p.rd(name)
        print(f"{name:12s} {v:#010x}  {v}")
    d = p.rd("PPS_DELTA")
    if d:
        print(f"clock        {d} Hz measured, {(d - a.nominal) / a.nominal * 1e9:+.1f} ppb vs {a.nominal}")


def cmd_watch(p: PpsCounter, a) -> None:
    if not p.wait_pps(3.0):
        sys.exit("no PPS edges (PPS_SEQ not advancing): check the PPS wiring on pmod0_d0")
    errs = []
    for i in range(a.n):
        if not p.wait_pps(1.5):
            print(f"{i:4d}  PPS missing"); errs.append(None); continue
        d = p.rd("PPS_DELTA")
        e = d - a.nominal
        errs.append(e)
        print(f"{i:4d}  PPS_DELTA {d}  err {e:+d} counts  {e / a.nominal * 1e9:+8.1f} ppb", flush=True)
    good = [e for e in errs if e is not None]
    locked = len(good) == len(errs) and all(abs(e) <= 1 for e in good)
    print(f"{len(good)}/{len(errs)} edges, error {min(good, default=0):+d}..{max(good, default=0):+d} counts"
          f" -> {'LOCKED to the reference' if locked else 'NOT locked (|err| > 1 count or missing PPS)'}")
    sys.exit(0 if locked else 1)


def cmd_capture(p: PpsCounter, a) -> None:
    import iio                                           # python3-libiio on Kuiper

    if not p.wait_pps(1.5):
        sys.exit("no PPS: refusing a GPS-gated capture")
    delta = p.rd("PPS_DELTA")
    m = a.ticks_per_sample
    rx_start = a.offset * m
    rx_stop = (a.offset + a.samples + a.samples // 2) * m
    if rx_stop >= delta - delta // 50:                    # close >= 20 ms before the next PPS
        sys.exit("offset + capture + margin leaves < 20 ms before the next PPS")
    p.gps_window(delta, rx_start, rx_stop)

    ctx = iio.Context("local:")
    ctx.set_timeout(int((a.ahead + 3) * 1000))
    dev = ctx.find_device(RX_DEVICE)
    if dev is None:
        sys.exit(f"IIO device {RX_DEVICE} not found")
    chans = [c for c in dev.channels if c.scan_element and not c.output]
    for c in chans:
        c.enabled = True

    t0 = int(time.time()) + a.ahead                      # target GPS second (UTC from NTP)
    time.sleep(max(0.0, t0 - ARM_LEAD_S - time.time()))
    lseq0 = p.rd("LATCH_SEQ")                            # snapshot BEFORE arming
    dev.attrs["sync_start_enable"].value = "arm"
    buf = iio.Buffer(dev, a.samples, False)
    buf.refill()                                         # returns once the window has opened
    lc, lseq, ppsc, delta = p.rd("LATCH_COUNT"), p.rd("LATCH_SEQ"), p.rd("PPS_COUNT"), p.rd("PPS_DELTA")
    data = buf.read()
    del buf
    dev.attrs["sync_start_enable"].value = "disarm"
    p.release()

    d = s32(lc - ppsc)
    if d < 0:                                            # read raced the next PPS
        d += delta
    ok = (lseq - lseq0) == 1 and 0 <= d < delta           # exactly this second's window
    ns = round(d / delta * 1e9)
    print(f"t0 {t0}  LATCH-PPS {d} ticks (expect RX_START+1 = {rx_start + 1})  LATCH_SEQ +{lseq - lseq0}")
    print(f"window opened  {t0}.{ns:09d}  (UTC second from the system clock)")
    print(f"sample[0]      {t0}.{round((d + TPL_START_TICKS) / delta * 1e9):09d}"
          f"  (+{TPL_START_TICKS} ticks in the RX core; RF latency not included)")
    print(f"{len(data)} bytes, {len(chans)} channels")
    if a.out:
        with open(a.out, "wb") as f:
            f.write(data)
        print(f"wrote {a.out}")
    sys.exit(0 if ok and d == rx_start + 1 else 1)


def cmd_chrony(p: PpsCounter, a) -> None:
    """Send chrony one PPS sample per second over its SOCK refclock protocol.

    chrony.conf:  server <jetson> iburst            # which second
                  refclock SOCK <socket> refid PPSC precision 1e-7 prefer
    The edge's local time is LIVE_COUNT - PPS_COUNT before the moment of the
    read; reads bracketed by more than --max-read-us are dropped.
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    while True:
        if not p.wait_pps(1.5):
            continue
        delta = p.rd("PPS_DELTA")
        if abs(delta - a.nominal) > a.nominal // 1000:
            continue                                      # PPS glitch or clock not up
        t_a = time.clock_gettime(time.CLOCK_REALTIME)
        live, ppsc = p.rd("LIVE_COUNT"), p.rd("PPS_COUNT")
        t_b = time.clock_gettime(time.CLOCK_REALTIME)
        if (t_b - t_a) * 1e6 > a.max_read_us:
            continue
        edge = (t_a + t_b) / 2 - ((live - ppsc) & 0xFFFFFFFF) / delta
        sec, frac = int(edge // 1), edge % 1.0
        offset = (1.0 - frac) if frac >= 0.5 else -frac    # true - local, within the second
        pkt = struct.pack("<qqdiiii", sec, int(frac * 1e6), offset, 1, 0, 0, 0x534F434B)
        try:
            sock.sendto(pkt, a.socket)
        except OSError as e:
            print(f"chrony socket {a.socket}: {e}", file=sys.stderr)
            time.sleep(1)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--base", type=lambda s: int(s, 0), default=BASE)
    ap.add_argument("--nominal", type=int, default=NOMINAL_HZ, help="expected counter Hz")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    w = sub.add_parser("watch")
    w.add_argument("-n", type=int, default=60, help="PPS edges to watch")
    c = sub.add_parser("capture")
    c.add_argument("-o", "--offset", type=int, default=0, help="samples after the PPS")
    c.add_argument("-n", "--samples", type=int, default=1_000_000)
    c.add_argument("--ahead", type=int, default=2, help="target this many seconds ahead")
    c.add_argument("--ticks-per-sample", type=int, default=1, help="core_clk_b ticks per IQ sample")
    c.add_argument("--out", help="write the raw interleaved int16 IQ here")
    k = sub.add_parser("chrony")
    k.add_argument("--socket", default="/var/run/chrony.ppsc.sock")
    k.add_argument("--max-read-us", type=float, default=50.0)
    a = ap.parse_args()
    p = PpsCounter(a.base)
    dict(status=cmd_status, watch=cmd_watch, capture=cmd_capture, chrony=cmd_chrony)[a.cmd](p, a)


if __name__ == "__main__":
    main()
