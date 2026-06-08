# pps_counter — FPGA GPS-timing counter (xo_correction / TDOA)

A small AXI4-Lite peripheral: a free-running counter on the AD936x **sample clock**,
with an optional hardware **PPS latch**. Lets Linux measure the AD936x reference
against GPS time, which is what `xo_correction` needs to discipline the clock —
and, with PPS wired into the PL, gives sample-accurate timestamps for TDOA.

See [`pps_counter.v`](pps_counter.v) for the RTL + full register map.

## Two modes

| Mode | Wiring | Precision | Use |
|---|---|---|---|
| **Software latch** | `pps_in` tied 0 (no extra pin) | ~µs (PPS IRQ jitter) | `xo_correction` (freq discipline) — **works now** |
| **Hardware latch** | PPS routed to a **PL pin** → `pps_in` | ~1 sample (ns) | TDOA absolute timestamps — needs a free PL pin |

Frequency discipline averages out the µs IRQ jitter, so the **software-latch mode
needs no extra FPGA pin** and is the recommended starting point.

## Integration into the Pluto HDL (ADI block design)

This is the part that takes build iterations. Outline:

1. **Add the RTL to the project** — in `hdl/projects/pluto/system_project.tcl`
   add the source:
   ```tcl
   add_files -norecurse $ad_hdl_dir/../pps_counter/pps_counter.v
   ```
2. **Instantiate + wire it in the block design** — in
   `hdl/projects/pluto/system_bd.tcl`:
   ```tcl
   create_bd_cell -type module -reference pps_counter pps_counter_0
   # counter clock = AD936x sample clock; reset from the system reset
   ad_connect  $sys_cpu_clk      pps_counter_0/s_axi_aclk
   ad_connect  sys_cpu_resetn    pps_counter_0/s_axi_aresetn
   ad_connect  axi_ad9361/l_clk  pps_counter_0/cnt_clk        ;# sample clock
   ad_connect  sys_cpu_resetn    pps_counter_0/cnt_resetn
   ad_connect  GND               pps_counter_0/pps_in         ;# SW-latch (no pin yet)
   # hook the AXI-Lite slave onto the PS interconnect at a free address
   ad_cpu_interconnect 0x43C00000 pps_counter_0
   ```
   (Exact net names — `sys_cpu_clk`, `axi_ad9361/l_clk` — may differ; the first
   build will tell us. For HW-latch later, replace the `GND` connect with the PPS
   PL pin and add an XDC line.)
3. **Force the HDL to rebuild** (the XSA target has no real prereqs):
   ```sh
   rm build/system_top.xsa
   ```
   then the normal `./docker-run.sh --vivado …` rebuilds the bitstream with the
   counter and repackages `pluto.frm`.

## Device tree / software access

Simplest: read the registers from userspace by `mmap`-ing `/dev/mem` at the
assigned base (`0x43C00000` above) — no driver needed:

```python
import mmap, os, struct, time
BASE = 0x43C00000
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m  = mmap.mmap(fd, 0x1000, offset=BASE)
def rd(off): return struct.unpack("<I", m[off:off+4])[0]
assert rd(0x00) == 0x50505343          # "PPSC" — IP present
# xo_correction loop: sample LIVE_COUNT once per second (e.g. on PPS) and
# compare the delta to the nominal sample rate -> frequency error -> tune
# /sys/bus/iio/devices/iio:device*/xo_correction (or via libiio).
```

(Optionally add a `generic-uio` DT node for `0x43C00000 0x1000` for a cleaner
interface than `/dev/mem`.)

## Status

- ✅ RTL written (`pps_counter.v`)
- ☐ Block-design integration (`system_bd.tcl`) — needs build iterations
- ☐ `xo_correction` userspace loop
- ☐ (later) PL pin for hardware PPS latch
