# Roadmap — resiliency & future work

Scope: the **timing/SDR node firmware** in this repo. The downstream application
stack — **VITA 49 streaming, AWS cloud streaming over Tailscale, and command &
control** — is tracked in a **separate application repo**, not here.

Priorities are ordered roughly by impact-for-effort.

## Timing resiliency

- **Holdover handling.** Today there is *no holdover*: lose GPS and the timing
  anchor + discipline are gone within seconds (and `xo_correct.sh` blocks waiting
  for PPS edges that stop coming).
  - Detect GPS/PPS loss → **freeze `xo_correction` at the last good value** (don't
    let it wander) and **flag the node's timestamps as `degraded`** so the fusion
    layer can downweight or drop it.
  - Bound the *usable* holdover window from the measured **Allan deviation**
    (already captured in `metrics/`): e.g. "good to ±X ns for Y seconds after GPS
    loss," then mark `invalid`.
  - *Hardware path:* feed an external **OCXO/Rb 10 MHz + 1PPS** (a real GPSDO)
    into the Pluto+ external-reference input for genuine holdover and lab-grade
    short-term stability — see *Hardware upgrade paths*.

- **GPS integrity (anti-spoof / anti-jam).** A localization net is only as honest
  as its time source.
  - **Bound-check `PPS_DELTA`** against an expected window and **reject outliers**
    before applying a correction (a bad second shouldn't yank the clock).
  - Monitor **satellite count / fix quality / HDOP**; flag low-confidence epochs.
  - **Cross-check** GPS-derived time against peer nodes (NTP/common-view); a node
    that disagrees with the consensus gets flagged.

- **Per-node health/quality telemetry.** Export `pps_present`, sat count, current
  `xo_correction` offset (ppm), recent ADEV, and die temperature so the
  coordinator knows each node's timing quality and can weight measurements. (This
  is *reporting*, distinct from C2.)

## Node robustness

- **`xo_correct` watchdog.** Add a timeout so a stalled PPS doesn't hang the
  daemon — re-enter the "wait for PPS lock" state and resume cleanly. (Pairs with
  the holdover freeze above.)
- **Hardware watchdog (Zynq WDT).** Auto-reboot if userspace wedges — important
  for an unattended field node.
- **Brick-resistance.** The unprotected QSPI is the #1 fragility. Keep a
  **known-good `boot.frm` + `pluto.frm` on the SD card** for automatic fallback
  boot, so a bad flash self-recovers instead of needing a bench visit.
- **Persistent logging.** Rootfs is RAM (logs vanish on reboot). Persist
  `xocorrect.log` + chrony tracking/stats to the SD card for post-hoc timing
  forensics.
- **Thermal logging.** Log Zynq **XADC die temperature** alongside the
  `xo_correction` value — TCXOs drift with temperature; correlating the two helps
  characterize (and later compensate) each node.

## TDOA accuracy

- **Sub-sample timestamping.** The ±1-sample (±32.6 ns) latch quantization is the
  current floor. A **TDC / PPS-phase interpolator** in the PL (sample the PPS edge
  with a faster clock) could push timing well below one sample period.
- **Per-node fixed-delay calibration.** Antenna + cable + the **F20 PPS path**
  delays are fixed per node and cancel in a time-*difference* **only if identical**
  across nodes. The current **resistor-divider level shift adds ~10 ns of RC delay**
  — replace it with a deterministic buffer (e.g. **74LVC1T45 at 1.8 V**) and
  characterize the residual per node so it truly cancels.
- **Common-view cross-validation.** Periodically compare two nodes' timing against
  a shared visible reference to catch a silently-bad GPS/timing node.

## Hardware upgrade paths

- **External 10 MHz / 1PPS reference input** (OCXO/Rb GPSDO) → holdover + orders-of-
  magnitude better short-term stability than the on-board TCXO.
- **Timing-grade GPS** (u-blox NEO-M8T, survey-in) → cleaner PPS and single-
  satellite timing holdover.
- **Proper F20 level shifter** (replaces the test resistor divider) → deterministic,
  low-jitter PPS into the hardware latch.

---

*See [TDOA_TIMING.md](TDOA_TIMING.md) for why these matter to localization accuracy.*
