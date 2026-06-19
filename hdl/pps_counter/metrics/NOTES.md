# pps_counter metrics — method, characterization, and detail

Background for the headline numbers in [`README.md`](README.md).

## What is measured

`PPS_DELTA` (reg `0x7C460014`) = AD936x sample-clock counts the hardware latch
captures between two consecutive GPS PPS rising edges — i.e. the sample-clock
frequency in Hz, once per true GPS second. Nominal is **30,720,000** counts/s
(the default 30.72 MHz rate). `PPS_SEQ` (`0x7C460018`) is the edge index, used as
the time axis. The latch needs the `--hwlatch` bitstream (PPS routed to F20); on
the software-latch build `PPS_DELTA` reads 0.

1 count = 1/30.72 MHz = **32.55 ns = 0.0326 ppm**. The latch is a single counter,
so a perfectly stable clock still dithers ±1 count — that is the resolution floor,
not noise.

## Capture conditions

| | |
|---|---|
| Date (UTC) | 2026-06-19 |
| Board | Pluto+ (Zynq-7010, xc7z010-1), `--hwlatch` firmware |
| Kernel | 6.1.0 |
| Nominal sample clock | 30.72 MHz (`in_voltage_sampling_frequency`) |
| GPS / clock state | stratum-1, PPS-disciplined, Leap Normal (system RMS offset ≈ 0.5 µs) |
| Counter | ID `PPSC`, `STATUS.pps_present = 1` |
| Each run | 600 PPS edges (~10 min), `PPS_DELTA` via `devmem` |

## Baseline (pre-correction) detail

```
mean PPS_DELTA  : 30,719,761.21 counts/s
freq offset     : -7.773 ppm   (-238.8 counts/s)
freq std        : 0.0193 ppm
jitter p2p      : 3 counts = 97.7 ns      (RMS 19.3 ns)
time-error slope: -7.773 us/s  (-671.61 ms/day)
ADEV @1s        : 1.74e-08
ADEV floor      : ~2.4e-09 near tau ~= 16 s
ADEV @128s      : 6.49e-09   (rising tail = TCXO thermal drift)
```

The clock is **−7.77 ppm slow** and very *stable* short-term (jitter at the ±1
count floor), but **drifts thermally** over 10 min (−7.74 → −7.79 ppm) — that
drift is what lifts the Allan deviation tail past τ ≈ 16 s. Baseline single-run
figures: [`baseline_freq_offset_ppm`](figures/baseline_freq_offset_ppm.png),
[`baseline_delta_hist`](figures/baseline_delta_hist.png),
[`baseline_allan`](figures/baseline_allan.png),
[`baseline_time_error`](figures/baseline_time_error.png).

## Actuator and plant

The stock board's TCXO is **not** voltage-controlled (`dcxo_tune_*` returns "No
such device" — external TCXO). The only live knob is the ad9361 `xo_correction`
sysfs attr: the driver's *assumed* reference frequency in Hz. Writing it re-solves
the clock dividers so the requested sample rate is produced from the corrected
reference, which moves the actual sample clock. Range `[39992000 … 40008000]`,
1 Hz steps.

A swept characterization (settle 2 edges, average 6) gives a clean linear,
monotonic, repeatable plant:

| xo_correction | PPS_DELTA | ppm |
|---|---|---|
| 40,000,000 | 30,719,760 | −7.81 |
| 39,999,900 | 30,719,837 | −5.31 |
| 39,999,800 | 30,719,914 | −2.80 |
| 39,999,689 | 30,719,999 | −0.03 |
| 39,999,600 | 30,720,067 | +2.18 |

Slope **−0.767 counts/Hz** (≈1.30 Hz/count, 0.025 ppm/Hz). The sign is negative —
raising `xo_correction` *lowers* `PPS_DELTA` — so the control step is the *same*
sign as the error: `dxo = +err × 1.30 Hz`. (Getting this backwards is positive
feedback and rails the knob.) `xo_correct.sh` applies a near-deadbeat step with a
1-count deadband, so it locks in ~1 update and then holds.

## Before/after figures

- **Frequency offset** ([`compare_freq_offset_ppm`](figures/compare_freq_offset_ppm.png)):
  −7.77 ppm bias collapses to ~0; the lone +49 ppm spike is a re-tune transient.
- **Steady-state distribution** ([`compare_hist`](figures/compare_hist.png)): the
  whole population shifts from −240 counts onto 0; the disciplined run is slightly
  wider (6 vs 3 counts p2p) — active-control dither.
- **Allan deviation** ([`compare_allan`](figures/compare_allan.png)): short-τ
  unchanged (both quantization-limited); the baseline thermal-drift upturn past
  τ ≈ 16 s is what disciplining bounds. A longer capture resolves the long-τ
  benefit better.

## Caveat: re-tune relock transients

`xo_correction` is not a voltage knob — every write makes the ad9361 **re-run its
PLL**, so the sample clock glitches ~tens of ppm for ~1 sample on each correction
(the +49 ppm spike; the single "transient" in the results table). Mitigations in
`xo_correct.sh`:

- a **1-count deadband** → it only re-tunes when drift exceeds the quantization
  floor (here: once in 10 min), not every second;
- the 2 samples after a write are excluded from the control average (relock
  settling).

For **TDOA**, additionally flag/ignore the GPS second containing a re-tune, or
discipline only between captures.

## Notes

- Discipline only holds while the loop runs; stop it and thermal drift resumes
  (crept to −0.6 ppm within ~2 min). The firmware autostarts the loop after a PPS
  lock on `--hwlatch` builds.
- No seed correction is applied at startup — TCXOs differ across boards, so the
  loop converges from whatever `xo_correction` is at boot (one startup glitch as
  it makes the first large step).
- Captures occasionally skip ~2% of PPS edges (the 1 s `sh` poll overshooting an
  edge); harmless for these statistics.
