# pps_counter — FPGA GPS-timing counter (xo_correction / TDOA)

A small AXI4-Lite peripheral: a free-running counter on the AD936x **sample clock**,
with an optional hardware **PPS latch**. Lets Linux measure the AD936x reference
against GPS time, which is what `xo_correction` needs to discipline the clock —
and, with PPS wired into the PL, gives sample-accurate timestamps for TDOA.

See [`pps_counter.v`](pps_counter.v) for the RTL + full register map (header comment:
counter, PPS latch, TDD frame and DMA-start latch registers, 0x00–0x40).

## Two modes

| Mode | Wiring | Precision | Use |
|---|---|---|---|
| **Software latch** | `pps_in` tied 0 (no extra pin) | ~µs (PPS IRQ jitter) | `xo_correction` (freq discipline) — **works now** |
| **Hardware latch** | PPS routed to a **PL pin** → `pps_in` | ~1 sample (ns) | TDOA absolute timestamps — needs a free PL pin |

Frequency discipline averages out the µs IRQ jitter, so the **software-latch mode
needs no extra FPGA pin** and is the recommended starting point.

> **Separate feature — the DMA-start latch (`LATCH_COUNT`/`LATCH_SEQ`, 0x3C/0x40).**
> Distinct from the `pps_in` latch above: `latch_trig` is driven by the RX-DMA sync
> itself — the output of the `dma_sync_or` gate (`dma_sync_or/Res` =
> `axi_tdd/tdd_channel_1 | pps_counter/tdd_enable`) — and captures the free-run counter
> at sample[0] of a TDD-gated capture → sample-exact GPS timestamp (`tdd_pps_latch`,
> ±~16 ns), whichever source opened the gate. Every bitstream this repo's build generates
> has it, with or without `--hwlatch`. Verify: `devmem 0x7C460040 32` should count up, not
> read `0x50505343`.
> *Historical:* added in commit `d329bbc` (ADDR_WIDTH 6→7). The released `v1.5`
> bitstream predates it: on that image 0x40 aliases the 0x00 ID (`0x50505343`), the latch
> never fires, and captures fall back to the `tdd_pps_window` anchor.

## Integration into the Pluto HDL (ADI block design)

**Automated** by `docker-build-inner.sh` (the `--vivado` build): it copies this
RTL into `hdl/projects/pluto/`, regenerates the pps_counter block at the end of
`system_bd.tcl` and `system_constr.xdc` on every run, and forces an XSA re-synth when
the integration changes. **The generated Tcl in `docker-build-inner.sh` (the
"Integrate pps_counter into the Pluto block design" step) is the source of truth**;
in outline it:

- adds the RTL and creates `pps_counter_0`, with `cnt_clk` = `axi_ad9361/l_clk`,
  `cnt_resetn` = `sys_cpu_resetn`, and the AXI4-Lite slave at `0x7C460000`
  (`ad_cpu_interconnect`);
- drives `pps_in` from a new top-level port `pps_ext` on `--hwlatch` builds (the XDC
  pins it to F20, LVCMOS18, pull-down; `system_top.v` is patched to match), or ties it
  to GND otherwise;
- disconnects `axi_tdd_0/sync_in` and drives it from `pps_counter_0/pps_tick` (kept
  but no longer relied on: without `sync_reset`, `axi_tdd` syncs only once, at enable);
- inserts a 2-input OR, `dma_sync_or`, in front of the RX-DMA sync:
  `axi_ad9361_adc_dma/sync = axi_tdd_0/tdd_channel_1 | pps_counter_0/tdd_enable`, and
  connects `dma_sync_or/Res` to `pps_counter_0/latch_trig`;
- adds the CDC `set_false_path` constraints.

Only `pps_in` depends on `--hwlatch`; the OR, the `sync_in` rewire and the latch are
generated either way. Real net names confirmed from the Pluto BD: AXI clock
`sys_cpu_clk` (`FCLK_CLK0`, 100 MHz), reset `sys_cpu_resetn`, sample clock
`axi_ad9361/l_clk`. The RTL is added *inside* `system_bd.tcl` (not
`system_project.tcl`) because the BD is built during `adi_project_create`, before the
top-level file list is added.

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

(Optionally add a `generic-uio` DT node for `0x7C460000 0x1000` for a cleaner
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
