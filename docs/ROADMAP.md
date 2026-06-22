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
  - ✅ **Bound-check `PPS_DELTA` / reject outliers** *(done)* — `xo_correct.sh` now
    rejects deltas beyond `MAXPPM` of the (auto-derived) nominal and holds the last
    good `xo` instead of railing; re-derives nominal on a sustained rate change.
    *Pending hardware validation.*
  - Monitor **satellite count / fix quality / HDOP**; flag low-confidence epochs.
  - **Cross-check** GPS-derived time against peer nodes (NTP/common-view); a node
    that disagrees with the consensus gets flagged.

- **Per-node health/quality telemetry.** Export `pps_present`, **live `PPS_SEQ` rate**
  (not the sticky `PPS_DELTA`), the **AD936x sample rate + `l_clk` multiple (1×/2×)**,
  current `xo_correction` offset (ppm), recent ADEV, and die temperature so the
  coordinator knows each node's timing quality and can weight measurements.
  **Sample rate is a system-of-systems fact, not a per-script assumption:** node tools
  read it from sysfs (`in_voltage_sampling_frequency`) and report it; the coordinator
  holds the authoritative per-node rate (nodes may legitimately differ, e.g. a 2×
  `l_clk` board), and fusion uses it rather than assuming a network-wide constant. (This
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

## GPS-scheduled TX/RX & coordination

- 🔧 **PPS-synced TDD** *(in flight)* — `pps_counter` gained a PPS-reset frame counter
  + a `pps_tick` output now driving `axi_tdd_0/sync_in`, so the (already DMA-gating)
  TDD frame is GPS-aligned. RTL + BD rewire done; feature build running. *Remaining:*
  on-device config/verify tooling + a two-node alignment test.
- **Compare-trigger IP** — extend `pps_counter` with a `TARGET`/`arm` compare that
  fires at an absolute GPS sample-time → one-shot scheduled events (two-way
  ranging, "TX at 12:00:00.000 GPS"). *(small new HDL)*
- **Coherent-on-receive** — estimate/correct residual inter-node carrier phase in
  post-processing on GPS-timestamped IQ. Achievable; big sensitivity/localization win.
- **Coherent TX beamforming** — long-horizon; needs a shared phase reference
  (distributed LO / White Rabbit) or closed-loop phase cal + RTK positions. *(research)*

Design + register sketch + the full beamforming requirements: **[SCHEDULING.md](SCHEDULING.md)**.

## Hardware upgrade paths

- **External 10 MHz / 1PPS reference input** (OCXO/Rb GPSDO) → holdover + orders-of-
  magnitude better short-term stability than the on-board TCXO.
- **Timing-grade GPS** (u-blox NEO-M8T, survey-in) → cleaner PPS and single-
  satellite timing holdover.
- **Proper F20 level shifter** (replaces the test resistor divider) → deterministic,
  low-jitter PPS into the hardware latch.

## Repo health & dev process (the missing dimension)

This roadmap covered features/hardware but not the repo's own robustness — and two
self-inflicted blockers this cycle (a dead Linaro URL, a clean-build `pipefail` crash)
show the gap.

- **Commit the working tree.** Big batch of verified-but-uncommitted work (Dockerfile
  toolchain fix, `xo_correct` rewrite, TDD RTL + BD wiring, `--prebuilt-bit`, build
  bugfix, docs). Branch, commit in logical chunks, tag a release.
- **CI / regression guard** *(none today)*. Minimum on PR: `bash -n`/shellcheck the
  `.sh` files + `xvlog` lint `pps_counter.v`. Stretch: an out-of-context `synth_design`
  smoke test. Either would have caught the `pipefail` bug.
- **Toolchain source is a 3rd-party image.** Dockerfile now pulls gcc-linaro from
  `azureiotedge/...`. Pin it by digest and document a fallback, or vendor the tarball
  (release asset / git-lfs) so a single deleted image can't break all builds.
- **Document the build environment** — WSL2 Vivado + Docker WSL integration + the
  `--prebuilt-bit` (no-Vivado) path. Currently only in session memory.
- **On-device tooling for the new TDD/`pps_counter` registers** — extend
  `read_counter.py` / add a `tdd_config.sh` (set `FRAME_LEN`/windows, configure
  `axi_tdd` at `0x7C440000`, read back `FRAME_POS`/`FRAME_SEQ`).
- **Pluto zeroconf address rotates** (`169.254.x` moved mid-session) — static
  link-local or consistent `pluto.local` use so node tooling stops chasing it.

---

*See [TDOA_TIMING.md](TDOA_TIMING.md) for why these matter to localization accuracy.*
