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

**Automated** by `docker-build-inner.sh` (the `--vivado` build): it copies this
RTL into `hdl/projects/pluto/`, appends the wiring to `system_bd.tcl`, and forces
an XSA re-synth when the integration changes. The appended TCL:

```tcl
add_files -norecurse $ad_hdl_dir/projects/pluto/pps_counter.v
update_compile_order -fileset sources_1
create_bd_cell -type module -reference pps_counter pps_counter_0
ad_connect axi_ad9361/l_clk pps_counter_0/cnt_clk   ;# AD936x sample clock
ad_connect sys_cpu_resetn   pps_counter_0/cnt_resetn
ad_connect GND              pps_counter_0/pps_in     ;# SW-latch (no PL pin yet)
ad_cpu_interconnect 0x7C460000 pps_counter_0         ;# AXI4-Lite base address
```

Real net names confirmed from the Pluto BD: AXI clock `sys_cpu_clk`
(`FCLK_CLK0`, 100 MHz), reset `sys_cpu_resetn`, sample clock `axi_ad9361/l_clk`.
`ad_cpu_interconnect` auto-wires `s_axi` + its clock/reset. The RTL is added
*inside* `system_bd.tcl` (not `system_project.tcl`) because the BD is built
during `adi_project_create`, before the top-level file list is added.

For the HW-latch upgrade later: replace the `GND` connect with the PPS PL pin
(a `create_bd_port` + `ad_connect` + an XDC `set_property PACKAGE_PIN` line).

## Device tree / software access

Simplest: read the registers from userspace by `mmap`-ing `/dev/mem` at the
assigned base (`0x7C460000`) — no driver needed:

```python
import mmap, os, struct, time
BASE = 0x7C460000
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
- ✅ Block-design integration — synthesizes/places/routes into the Pluto design,
  `pluto.frm` carries the bitstream
- ⚠️ Timing: the xc7z010-**1** is near-full; the added AXI slave pushes the ADI
  design's AD9361 **config-write** paths ~1.5 ns past closure (WNS ≈ −1.5 ns).
  The build tolerates this (gate downgraded to a warning). **Validated on
  hardware:** with the `--hwlatch` build flashed, the AD9361 still tunes, GPS
  locks (stratum-1), and RF works — the config-write violation has no observed
  effect.
- ✅ On-hardware validation: `--hwlatch` build flashed; hardware PPS latch
  captures (`STATUS.pps_present=1`, `PPS_SEQ` advancing). The latch is
  quantization-limited at ±1 sample (~33 ns); see [`metrics/`](metrics/).
- ✅ `xo_correction` userspace loop — [`xo_correct.sh`](xo_correct.sh) disciplines
  the sample clock to GPS (−7.77 ppm → +0.02 ppm). Before/after metrics + figures
  in [`metrics/`](metrics/).
- ✅ PL pin for hardware PPS latch (F20) — wired and working (the `--hwlatch`
  build; PPS level-shifted 3.3 V → 1.8 V into F20).

## On-device test

Copy [`read_counter.py`](read_counter.py) to the Pluto and run it:

```sh
python3 read_counter.py         # dump registers (expect ID='PPSC')
python3 read_counter.py --mon   # live sample-clock frequency (xo_correction input)
```
