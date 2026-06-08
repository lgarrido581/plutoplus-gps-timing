#!/usr/bin/env python3
# read_counter.py - read/monitor the pps_counter FPGA peripheral on the Pluto+.
#
# Run ON the Pluto (it mmaps /dev/mem):
#   python3 read_counter.py            # one-shot register dump
#   python3 read_counter.py --mon      # monitor: sample-clock Hz once per second
#
# Register base is the AXI address assigned in system_bd.tcl (0x7C460000).
import mmap, os, struct, sys, time

BASE = 0x7C460000
REGS = {0x00: "ID", 0x04: "CTRL", 0x08: "STATUS", 0x0C: "LIVE_COUNT",
        0x10: "PPS_COUNT", 0x14: "PPS_DELTA", 0x18: "PPS_SEQ"}

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
# mmap offset must be page-aligned; BASE is 4K-aligned so this is fine.
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
              offset=BASE)

def rd(off):
    return struct.unpack("<I", m[off:off+4])[0]

ident = rd(0x00)
if ident != 0x50505343:  # "PPSC"
    print(f"ERROR: ID=0x{ident:08X}, expected 0x50505343 ('PPSC'). "
          f"Is the counter in this bitstream / is the address right?")
    sys.exit(1)
print("pps_counter present (ID='PPSC') @ 0x%08X" % BASE)

if "--mon" in sys.argv:
    # Sample LIVE_COUNT once per second -> delta == AD936x sample-clock Hz.
    # This is the raw measurement xo_correction disciplines against GPS.
    prev = rd(0x0C); prev_t = time.monotonic()
    print("monitoring sample clock (LIVE_COUNT delta / elapsed)...  Ctrl-C to stop")
    while True:
        time.sleep(1.0)
        now = rd(0x0C); now_t = time.monotonic()
        d = (now - prev) & 0xFFFFFFFF            # modulo-2^32 (handles wrap)
        dt = now_t - prev_t
        print(f"  {d/ dt/1e6:10.6f} MHz   (delta={d}, dt={dt:.4f}s)")
        prev, prev_t = now, now_t
else:
    for off, name in REGS.items():
        print(f"  0x{off:02X} {name:<11} = 0x{rd(off):08X} ({rd(off)})")
