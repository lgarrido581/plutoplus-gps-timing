# Prebuilt bitstreams

Known-good FPGA bitstreams so a firmware build can skip Vivado
(`docker-run.sh --prebuilt-bit <this .bit> --hwlatch`).

## `system_top_hwlatch.bit`

- **md5:** `191836d682922df65d3c84cbe7f9ab7b`  ·  **964,108 bytes**  ·  target `xc7z010clg225-1`
- **Contents:** the full Pluto PL — `axi_ad9361` + `axi_dmac` + ADI `axi_tdd` (`iio-axi-tdd-0`
  @ `0x7C440000`) + `pps_counter` (@ `0x7C460000`) **including the DMA-start latch**
  (`LATCH_COUNT`/`LATCH_SEQ` at `0x3C`/`0x40`, HDL commit `d329bbc`, `ADDR_WIDTH` 6→7) and
  the `--hwlatch` F20 PPS input. This is what enables the sample-exact
  `gpsanchor:method == "tdd_pps_latch"` capture anchor.
- **Why it exists:** the released **v1.5 bitstream predates `d329bbc`** — its `pps_counter`
  has a 6-bit address decode, so `0x40` aliases the `0x00` ID (`0x50505343`) and the latch
  can never fire (every capture falls back to `tdd_pps_window`). This bitstream adds the
  latch registers so `tdd_pps_latch` works.

### How it was built

Natively with **Windows Vivado 2022.2** (`F:\Xilinx`), *not* the Docker container (the
container only builds the firmware/rootfs and takes the bitstream via `--prebuilt-bit`):

1. `sardylan/plutoplus` (`fw-0.39`) → `plutosdr-fw` → `hdl` submodule (sardylan's ADI-hdl
   fork, **`2022_r2`** — native to Vivado 2022.2). Its Pluto BD already instantiates
   `axi_tdd`.
2. Drop in `hdl/pps_counter/pps_counter.v` (the `d329bbc` latch) and run the BD-integration
   + timing-gate steps from `docker-build-inner.sh` (wire `pps_tick → axi_tdd/sync_in`,
   fan out `tdd_channel_1 → latch_trig`, add the F20/CDC constraints).
3. Package the ADI library IP, then build the project, with
   `ADI_IGNORE_VERSION_CHECK=1` (the hdl checks for 2023.2; 2022_r2 builds fine on 2022.2).

### Timing caveat

WNS ≈ **−3.58 ns** — all failing paths are inside `axi_ad9361` (its internal TDD control
regs at ~−1.7 ns and the RX source-synchronous crossing at −3.6 ns), the same inherent
near-full-`xc7z010-1` paths the ADI/`--hwlatch` build tolerates (gate downgraded to a
warning). The `pps_counter`/latch logic itself has **zero** failing paths (false-pathed
CDC). Verify RX health on hardware.

> ⚠️ **Status: built, NOT yet hardware-validated** as of this commit. Validate before relying
> on it: flash `--prebuilt-bit system_top_hwlatch.bit --hwlatch`, then on the device
> `devmem 0x7C460040 32` must **count up** (not read `0x50505343`), a `tdd_sync` capture must
> report `method=tdd_pps_latch`, and RX must still tune/capture cleanly. Recover with the v1.5
> bitstream if anything's off.
