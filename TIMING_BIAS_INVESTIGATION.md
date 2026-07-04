# Pluto+ GPS-anchored capture — constant timing-bias investigation

> ## CLOSED (2026-07-04) — not a firmware bias; timing chain verified to ~0.2 µs
> Executed below. Findings:
> - **Steps 1–2:** both radios' gates open 0–200 ns after their own PPS (latch-measured),
>   `RX_START=0` both, `cnt_hz` identical. Gate coincident; labels truthful.
> - **Chain check:** AD9361 RX paths identical on both (same decimation ladder, FIR off,
>   same bandwidth/governor/gain). No group-delay differential.
> - **Steps 4–6 (paired-capture experiments, both radios, same GPS second):** residual
>   (measured − geometry) vs three known transmitters:
>   94.7 run1 **−6.5 µs**, 94.7 run2 (25 min later) **−1.6 µs**, 100.3 (8 s after run2)
>   **+0.24 µs**. Not common across stations and not constant in time ⇒ NOT instrumental.
>   The 100.3 (Empire State, elevated near-LOS) result verifies the ENTIRE chain —
>   RF → PPS-anchored gate → hardware latch label → correlation → geometry — to ~±0.3 µs.
> - **Root cause of the ~7 µs:** 94.7-specific multipath (dominant-path state; coherent for
>   minutes–hours, wanders after). A host-side constant calibrated against 94.7 bakes in a
>   propagation snapshot and over-corrects every other emitter.
> - **No firmware change required.** Success criterion met: the radios' true sample[0] vs
>   GPS agrees end-to-end at the sub-µs level (0.24 µs against a live reference).
> - Recommendations (host side): calibrate against an elevated near-LOS reference (or none),
>   validate on a second station, and prefer a median over several dwells to a single-shot.

Goal: find and remove, **in firmware**, a constant timing bias between two Pluto+ radios'
GPS-anchored captures. The bias is a fixed offset (not drift). It is currently corrected by a
host-side constant; we want the two radios' capture timing to agree at the hardware level so no
host correction is needed.

## Current firmware state (baseline for this work)

- Branch `feature/coincident-pps-capture` @ `a6ded39` (off v1.8), flashed to both radios and
  validated. The RX capture window is gated on `pps_counter`'s PPS-anchored frame instead of the
  free-running `axi_tdd` frame:
  `adc_dma/sync = axi_tdd/tdd_channel_1 | pps_counter/tdd_enable` (a 2-input OR).
  `pps_counter` reloads its frame to 0 on every PPS edge, so the window opens at
  `RX_START` counts after each PPS. A gated capture disables `axi_tdd` so the OR passes
  `pps_counter/tdd_enable`; the DMA-start latch observes the OR output.
- Validated: cross-radio window-open delta (the `gps_ns0` difference for matched cycles)
  dropped from milliseconds-and-accumulating to **0–200 ns bounded**; every capture reports
  `method=tdd_pps_latch`, `latch_rms=16 ns`. Keep this behavior — this task fixes a residual
  **constant** offset on top of it, not by reverting it.

## Symptom

- After the coincident-capture change above, a **constant ~7 µs offset** appeared between the
  two radios' captured sample streams, measured relative to what their `gps_ns0` timestamps
  claim. With the previous firmware (free-running window + host label-shift) this offset was not
  present.
- It is a fixed bias: constant over time, and (expected) frequency-independent. A single
  constant applied host-side cancels it, which is consistent with a per-radio capture-timing
  constant rather than anything signal- or geometry-dependent.

## The key discrepancy to explain

The `gps_ns0` labels report the two captures as coincident (delta ≈ 0–200 ns). Yet the actual
captured samples are offset by ~7 µs. So on at least one radio there is a **systematic
difference between the labeled time of sample[0] (`gps_ns0`) and the true time of sample[0]**,
and that difference is not the same on both radios.

## Leading hypothesis

Per-radio window offset (`RX_START` = `offset_samples`). The capture request carries a window
offset that was originally chosen to line up the OLD free-running windows / absorb each radio's
arm latency. Under the new PPS-anchored window, `RX_START` becomes a fixed PPS-relative
window-open offset. If the two radios are programmed with **different** `RX_START` (or run at a
slightly different `cnt_clk`/sample rate), the window-open times differ by a fixed
`Δ(RX_START) / fs`. A few samples' difference at the capture rate is single-digit µs —
consistent with ~7 µs. `gps_ns0` is computed as `last_pps_ns + RX_START/fs` (or from the latch),
so a per-radio `RX_START` that the downstream timing assumes is identical would show up exactly
as this constant offset.

Other candidates to rule in/out: a constant pipeline latency from the gate edge to sample[0] in
the DMA that differs per radio; a `cnt_clk` vs sample-rate mismatch; the latch measuring the
gate edge while sample[0] lands a fixed number of samples later.

## Investigation steps

Read-only register probing on each radio uses `devmem` over the board's SSH (root/analog). Do
NOT reprogram `axi_tdd` on a live radio (that reprograms the capture core).

pps_counter base `0x7C460000`:
`0x08` STATUS, `0x0C` LIVE_COUNT, `0x10` PPS_COUNT, `0x14` PPS_DELTA (= cnt_clk Hz when locked),
`0x18` PPS_SEQ, `0x1C` TDD_CTRL (b0 enable, b1 pps_sync_en, b2 drive_pins), `0x20` FRAME_LEN,
`0x24` RX_START, `0x28` RX_STOP, `0x34` FRAME_POS, `0x3C` LATCH_COUNT, `0x40` LATCH_SEQ.
axi_tdd base `0x7C440000`. Key source: `services/capture_core.c` (capture path + `gps_ns0`),
`services/pps_timestamp.c` (`gps_ts_*`, `pps_ts_config_frame`, the `gps_ns0` math),
`hdl/pps_counter/pps_counter.v` (window logic), `docker-build-inner.sh` (the BD/OR-gate patch).

1. **Compare the programmed capture parameters on both radios for the same dwell:** read
   `RX_START`, `RX_STOP`, `FRAME_LEN`, `PPS_DELTA` (cnt_clk Hz), `TDD_CTRL`. Is `RX_START`
   (or the effective sample rate) different between the two radios? By how many samples, and does
   `Δ(RX_START)/fs` ≈ 7 µs?

2. **Measure the true time of sample[0] relative to the PPS on each radio, independent of the
   label:** compute `(LATCH_COUNT − PPS_COUNT) mod 2^32` (cnt_clk ticks from the PPS edge to the
   latched sample[0]); convert to seconds with `PPS_DELTA`. Compare the two radios. This is the
   ground-truth window-open phase; the difference between the two radios is the physical part of
   the bias.

3. **Compare that measured phase to what `gps_ns0` reports.** In `capture_core.c`/`pps_timestamp.c`,
   `gps_ns0`'s sub-second is derived from the latch (`lgps`) or from `RX_START/fs`. Confirm which
   path runs (`method=tdd_pps_latch` ⇒ latch). Check whether the label reflects the measured
   phase from step 2 or assumes a fixed offset that does not match it.

4. **Quantify the gate-to-sample[0] pipeline delay.** Determine the fixed latency from
   `pps_counter/tdd_enable` (the OR output) rising to the first sample written to the DMA buffer,
   and whether it is identical on both radios. A scope check (PPS on one channel, the RX-DMA sync
   or a GPIO mirror on the other) gives PPS→window-open per radio; a known off-air reference
   captured by both radios gives PPS→sample[0] end-to-end.

5. **Reconstruct the old vs new behavior.** Under the previous firmware, `RX_START`/on_raw was
   relative to the free-running `axi_tdd` frame and the host label-shift + drift absorbed any
   net per-radio offset. Show why the old path had ~0 net cross-radio offset and the new
   PPS-anchored path exposes ~7 µs. This confirms whether the fix is to normalize `RX_START`
   across radios, or to make `gps_ns0` track the true latched phase, or both.

6. **Characterize the bias:** confirm it is constant over time, the same across tune
   frequencies, and reverses sign if the two radios swap roles. That pins it as a per-radio
   capture-timing constant.

## Success criteria

- Root cause identified in the firmware/capture path.
- A firmware change (services and/or HDL) that makes both radios' true sample[0] time, relative
  to the GPS PPS, agree to within the latch quantization (~16 ns) — removing the need for any
  host-side timing-bias constant, while keeping the PPS-anchored coincident-capture behavior.

## Constraints

- All firmware / FPGA / Zynq changes live in this standalone `plutoplus-gps-timing` repo (a
  generic Pluto+ precise-GPS-timing project). Keep it generic — no downstream-application
  content. Build the `.frm` per `docs/BUILD.md` (native Vivado 2022.2 → `system_top.bit` →
  `docker-run.sh --prebuilt-bit <bit> --hwlatch`), flash with `flash_frm.py --host <ip>`
  (`-F never` in any downstream deploy so the radios are not reflashed from a stale baked image).
- Preserve the coincident (PPS-anchored) capture — `method` must stay `tdd_pps_latch` and the
  cross-radio window delta must stay sub-µs and bounded.
- Leave the host-side constant correction in place as a safety net until the firmware fix is
  validated on hardware.
