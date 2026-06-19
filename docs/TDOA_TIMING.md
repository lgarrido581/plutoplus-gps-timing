# What GPS sample-clock discipline buys for TDOA

Reference note on how the FPGA `pps_counter` and the `xo_correction` discipline
(v1.3) actually affect TDOA localization. **Short version:** the hardware PPS
latch is the real enabler; `xo_correction` is a refinement on top of it, and its
biggest payoff is carrier coherence, not raw per-second timing.

Position error scales with timing error at **≈ 0.3 m per ns** (`c`), amplified by
geometry (GDOP).

## Timing floor — set by the latch, not by xo_correction

`pps_counter` anchors sample-index to GPS time at every PPS edge. It is
quantization-limited to **±1 sample = ±32.6 ns ≈ ±10 m** single-shot (at
30.72 MHz). Averaging N independent PPS measurements pulls that down ~`1/√N`:

| measurement window | timing | ≈ position |
|---|---|---|
| single PPS | ±32.6 ns | ±10 m |
| ~100 s averaged | ±3.3 ns | ±1 m |

`xo_correction` does **not** change this floor — it's the latch resolution.

## What the ppm improvement (−7.77 → +0.02 ppm) actually buys

A clock offset `ε` matters two ways.

### 1. Intra-second drift — modest, and partly redundant with the latch

Between PPS edges the clock drifts by `ε × T`:

| | offset | drift / 1 s | mid-second error | ≈ position |
|---|---|---|---|---|
| before | −7.77 ppm | 7.8 µs | 3.9 µs | ~1.2 km |
| after | +0.02 ppm | 20 ns | 10 ns | ~3 m |

**Caveat:** if the pipeline converts sample→time with the **measured `PPS_DELTA`**
(actual samples that GPS-second) instead of the nominal 30.72 MHz, this drift is
already calibrated out *regardless* of `xo_correction`. So here the discipline
mainly buys **robustness** (no reliance on perfect per-second interpolation) and
keeps `PPS_DELTA` parked at nominal.

### 2. Carrier coherence — the big one

The LO and the sample clock both derive from the same TCXO, so a 7.77 ppm clock
error is also a 7.77 ppm **carrier** error. At a 1 GHz carrier, between two nodes:

| | relative CFO @ 1 GHz | max coherent integration (~1/CFO) |
|---|---|---|
| before | ~7,770 Hz | ~130 µs |
| after | ~20 Hz | ~50 ms |

A large inter-node carrier frequency offset (CFO) **smears the cross-correlation
peak** and caps coherent integration. Cutting it ~400× lets you integrate far
longer → more processing gain → a **sharper, more confident TDOA peak on weak
signals**, and it's a prerequisite for **FDOA** (velocity) if added later.

## Bottom line

- **Latch (foundation):** the GPS↔sample anchor — ~10 m single-shot, ~1 m
  averaged. Without it there is no TDOA.
- **`xo_correction` (refinement):** turns a potential ~km-scale interpolation
  blunder into a non-issue, parks the rate at nominal, and — most valuably —
  collapses inter-node carrier offset ~400×, enabling long coherent integration
  on weak emitters.

Not a 400× gain in *position accuracy* (that's quantization/GDOP-limited), but the
difference between a demo on strong nearby signals and a system that detects and
correlates the weak, real-world emitters you actually care about.

**Caveat:** TCXO-class and **GPS-dependent — no holdover.** Lose GPS at a node and
within seconds both its timing anchor and this discipline are gone, so every node
needs its own solid GPS fix. See [ROADMAP.md](ROADMAP.md) for holdover/integrity work.
