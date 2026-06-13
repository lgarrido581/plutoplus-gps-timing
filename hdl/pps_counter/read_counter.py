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

def wr(off, val):
    m[off:off+4] = struct.pack("<I", val & 0xFFFFFFFF)

ident = rd(0x00)
if ident != 0x50505343:  # "PPSC"
    print(f"ERROR: ID=0x{ident:08X}, expected 0x50505343 ('PPSC'). "
          f"Is the counter in this bitstream / is the address right?")
    sys.exit(1)
print("pps_counter present (ID='PPSC') @ 0x%08X" % BASE)

if "--gpio" in sys.argv:
    # I/O voltage test (pluto-gpiotest.frm only): drive F20/F19 high/low via
    # CTRL[5:4], then measure the pin with a DMM (high == bank-35 VCCO).
    #   python3 read_counter.py --gpio f20 1     # drive F20 high
    #   python3 read_counter.py --gpio f19 0     # drive F19 low
    i = sys.argv.index("--gpio")
    bit = {"f20": 4, "0": 4, "f19": 5, "1": 5}[sys.argv[i+1].lower()]
    val = int(sys.argv[i+2])
    cur = rd(0x04)
    cur = (cur | (1 << bit)) if val else (cur & ~(1 << bit))
    wr(0x04, cur | 0x1)                       # keep counter enabled (bit0)
    c = rd(0x04)
    print(f"CTRL=0x{c:08X}  F20(bit4)={'HIGH' if c & 0x10 else 'low'}  "
          f"F19(bit5)={'HIGH' if c & 0x20 else 'low'}")
    sys.exit(0)

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
