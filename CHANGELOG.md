# Changelog

All notable changes to this project. Versions are git tags.

## Unreleased — Networked TDOA (Phase 2)
- **`docs/NETWORK.md`:** architecture for a multi-site passive-localization network — Jetson Nano
  edge nodes (Pluto+ over libiio) on a **Tailscale** tailnet reporting to a cloud coordinator.
  Decisions: **hybrid** compute (edge GPU reduce on the Nano → cloud TDOA fusion) and a
  **transport-agnostic** cloud target (self-hosted VPS *or* managed object storage behind one
  `push()` interface). The Pluto stays off Tailscale (fragile QSPI); the Nano is the only tailnet
  node. Tailscale is transport, not a time source — per-site GPS keeps WAN jitter out of timing.
- **`tdoa/node/bringup.sh`:** per-site bring-up — installs/links Tailscale on the Nano, verifies the
  Pluto over libiio (+ surfaces its chrony/PPS health), and smoke-tests cloud reachability.

## v1.5 — Holdover & timing-quality state (GPS-loss safety)

When PPS drops, the node now fails **safe and visible** instead of silently drifting.

- **`xo_correct.sh` holdover state machine:** if PPS edges stop for ≥`PPS_TIMEOUT` (3 s), the loop
  detects it (no longer blocks forever), **freezes `xo_correction`** at its last good value, and
  publishes a timing-quality state the node agent / coordinator reads to weight or drop the node:
  `LOCKED | CORRECTING | PPS_GLITCH | HOLDOVER_GOOD | HOLDOVER_DEGRADED | INVALID`. Holdover escalates
  `GOOD→DEGRADED→INVALID` by elapsed time (`HOLD_GOOD_S`/`HOLD_INVALID_S`, tune from `metrics/` ADEV vs
  your TDOA budget); on PPS return it logs recovery and re-acquires. State is written atomically to
  `STATE_FILE` (default `/run/xo_state`):
  `state=LOCKED holdover_s=0 xo=… nominal=… last_delta=… last_ppm=… ts=…`
- **Validated:** holdover escalation proven in a mocked-PPS self-test; the `LOCKED` path + state-file
  write confirmed on real hardware (auto-derive, lock, `+0.033 ppm`, state file).
- **Same bitstream as v1.4** (rootfs/firmware only) — built via `--prebuilt-bit` (no Vivado); the
  packaged `fpga` node is byte-identical (`sha256 b9d50963…`). The on-board TCXO holds *fine* timing
  only ~seconds; long holdover still needs an external OCXO/Rb reference (ROADMAP). Reflash to get the
  new daemon, or just `scp` the script to test.
- **`S70xocorrect` autostart fix:** the init script gated on `pps_present` on its *first line*, which
  at cold boot (GPS not locked yet) is 0 → it "skipped" and never retried, so `xo_correct` didn't
  autostart until manually kicked. Now the background waiter **polls for both `pps_present` and a chrony
  PPS lock**, then disciplines — robust across a cold boot.
- **Build fixes for the `--prebuilt-bit` / no-Vivado path** (`docker-build-inner.sh`): (1) a silent
  `set -euo pipefail` crash on `ls "$VIVADO_PATH"/Vivado/*/settings64.sh | head` when no Vivado is
  present (`|| true`); (2) buildroot overlays aren't dependency-tracked, so an edited overlay (e.g.
  `xo_correct.sh`) didn't invalidate the cached rootfs image and silently never shipped — now the
  rootfs image + `pluto.frm` are force-rebuilt so overlay edits take effect.

## v1.4.1 — TDD tooling robustness (no firmware change)

Scripts/docs only — **no bitstream/firmware change, no reflash needed.**

- **`tdd_verify.sh`** no longer infers the rate from the *sticky* `PPS_DELTA`. It reads the
  authoritative AD936x sample rate from **sysfs** (`in_voltage_sampling_frequency`, works without PPS),
  judges PPS liveness by **`PPS_SEQ` advancing**, and cross-checks `l_clk` vs sysfs (reports 1×/2×).
  When PPS isn't live it exits with a clear **`NO LIVE PPS`** verdict + the F20 check, instead of a
  misleading derived rate (which previously made a no-PPS board print `l_clk≈61.44 MHz` from a stale latch).
- **`tdd_tx_test.sh`** (new): sets up a GPS-aligned, TDD-gated TX burst for measuring **TX-vs-PPS timing
  on a scope** (delay = per-node fixed latency, jitter ≤1 sample, drift = lock quality). Same
  sysfs-rate + live-PPS gating.
- **Docs:** `TDD_PPS_DESIGN.md` gains Testing + PPS-loss/holdover sections; `ROADMAP.md`/`NETWORK.md`
  make explicit that **sample rate is tracked at the coordinator** (nodes read+report it; fusion uses
  each node's reported rate, never a global constant — required since nodes may run different rates).

## v1.4 — GPS-aligned TDD + disciplined-clock robustness

**Headline:** the AD936x **TDD frame is now phase-locked to GPS time**. Combined with the existing
sample-clock discipline, every node's TX/RX windows start on the same GPS-second boundary — the
foundation for coordinated, multi-node capture/transmit.

- **PPS-aligned TDD** (`hdl/pps_counter/`): `pps_counter` gained a frame counter in the `l_clk`
  domain plus a **`pps_tick`** output (1-cycle pulse on each PPS edge). `docker-build-inner.sh`
  rewires ADI's `axi_tdd_0/sync_in` (formerly the unused external `tdd_ext_sync` port) to `pps_tick`,
  so `axi_tdd`'s frame counter re-anchors to the GPS second every PPS — same `l_clk` domain, no CDC.
  New AXI registers `0x1C–0x38` (`TDD_CTRL`, `FRAME_LEN`, RX/TX windows, `FRAME_POS`, `FRAME_SEQ`);
  disabled by default (powers up identical to v1.3). Design: [docs](hdl/pps_counter/TDD_PPS_DESIGN.md).
- **`tdd_verify.sh`** — on-device functional proof: confirms the sample clock is locked, the frame
  counter stays bounded and re-anchors on every PPS, and `axi_tdd` is in external-sync mode consuming
  `pps_tick`. **Validated on hardware** (`PASS`, `FRAME_SEQ` 0..~100, `axi_tdd CONTROL=0x9`). Software
  reads are ms-jittery so this proves *function*; ns/sample precision needs a scope or two-node
  cross-correlation (precision floor ±1 sample ≈ 32.6 ns until a PPS-phase TDC is added).
- **`xo_correct.sh` robustness** — (1) **auto-derives `NOMINAL`** from the live AD936x sample rate ×
  the measured `l_clk` multiple, so it locks on any clocking (e.g. a board running `l_clk` at 2×);
  (2) **rejects outlier `PPS_DELTA`** (missed/spurious PPS edges) and holds the last good `xo` instead
  of railing the knob; (3) **re-derives on a sustained rate change**. Plant gain + outlier band scale
  with the derived rate.
- **Build resiliency:** the dead `releases.linaro.org` toolchain URL is replaced with a `COPY --from`
  of the identical `gcc-linaro-7.3.1-2018.05` toolchain (unblocks all builds); a clean-build
  `set -euo pipefail` crash (`find … | head` on a missing dir) is fixed; and **`--prebuilt-bit`**
  lets a script/rootfs-only release reuse a known-good bitstream with no Vivado.

## v1.3 — FPGA GPS-timing counter
- **Vivado-in-Docker build path:** `docker-run.sh --vivado <XilinxPath>` rebuilds the FPGA bitstream
  in-container and repackages it into `pluto.frm`, reusing the stock `boot.frm` (PL-only "Option B"
  flow — no Vitis/FSBL). Fixes for the headless Vivado run (libudev `/sys`, fakeroot, cached XSA).
- **`pps_counter` IP** (`hdl/pps_counter/`): AXI-Lite counter on the AD936x sample clock at
  `0x7C460000`, with software-latch (`LIVE_COUNT`) and optional hardware **PPS latch** for
  `xo_correction` / TDOA. Auto-integrated into the Pluto block design by `docker-build-inner.sh`.
- **Build flags:** `--hwlatch` (F20 PPS input, ns latch) and `--gpio-test` (drive F20/F19 to validate
  bank-35 I/O voltage → `pluto-gpiotest.frm`). On-device tooling via `devmem` + `read_counter.py`.
- **Validated on hardware:** the `--hwlatch` build is flashed and working — the hardware PPS latch
  captures (`STATUS.pps_present=1`, `PPS_SEQ` advancing), GPS still locks (stratum-1), and RF tunes
  despite the ~-2.5 ns AD9361 *config-write* setup violation (the build-flow override is safe). The
  latch is quantization-limited at ±1 sample (~33 ns).
- **`xo_correction` discipline loop** (`hdl/pps_counter/xo_correct.sh`): samples the hardware-latched
  `PPS_DELTA` against GPS and steers the ad9361 `xo_correction` knob (linear plant, −0.767 counts/Hz)
  to null the sample-clock offset — **−7.77 ppm → +0.02 ppm**, turning an unbounded −672 ms/day drift
  into a bounded hold. (Note: each correction triggers a PLL relock glitch of ~1 sample; a 1-count
  deadband keeps re-tunes rare.) **Autostarted** on `--hwlatch` builds by a new `S70xocorrect` init
  script that waits for a chrony PPS lock first (no seed correction — converges from boot). The
  poll loop sleeps ~0.2 s between the 1 Hz PPS edges, so the daemon idles the CPU instead of
  spinning a core.
- **Metrics package** (`hdl/pps_counter/metrics/`): capture + analysis pipeline (`capture_pps_delta.sh`,
  `capture_and_correct.sh`, `analyze.py`, `compare.py`) with before/after datasets, figures, and a
  writeup quantifying the disciplining (frequency offset, jitter, Allan deviation, cumulative time error).
- **Documented I/O levels (Pluto+ V2):** PL banks (F20/F19) = 1.8 V; PS MIO bank 500 (MIO9) = 3.3 V.

## v1.2
- **NTP/IPv6 fix:** also allow **IPv6 link-local** clients (`allow fe80::/10`). The v1.1 allow list
  was IPv4-only, so NTP queries that resolved to the Pluto's `fe80::` address (the common case over
  `eth0`/`pluto.local`) were silently dropped. Verified serving to a Windows host over `pluto.local`.

## v1.1
- **NTP server:** chrony now serves time to the LAN (`allow` for RFC1918 ranges); the device is a
  **stratum-1, GPS-backed NTP server** once it holds a PPS lock (it won't serve bad time before lock).
- **TDOA tooling:** added `tdoa/` with GPS-timestamped IQ capture scripts
  (`capture_gps_timestamped.sh`, `capture_timestamp.py`) and a TDOA roadmap.

## v1.0
Initial, verified-working firmware: GPS-disciplined time on the Pluto+.

- **PPS** on **MIO9** (`pps-gpio` → `/dev/pps0`); `CONFIG_PPS` + `CONFIG_PPS_CLIENT_GPIO`.
- **GPS NMEA** on **UART1** (MIO12/13) → **`/dev/ttyPS0`**; gpsd auto-starts at **9600** with `-n -b`.
- **chrony** with the **PPS refclock compiled in** (via `pps-tools`/`timepps.h`) + shipped
  `/etc/chrony.conf` (GPS SHM + PPS).
- Diagnostics: `ppstest`, `gpsmon`, `cgps`, `gpspipe`.
- Serial login **getty removed** from `ttyPS0` so it doesn't fight gpsd.
- **U-Boot `bootdelay=-2`** (auto-applied by `S30bootdelay`) so the GPS NMEA stream can't abort
  autoboot.
- Dockerized build on `sardylan/plutoplus` `fw-0.39`; no Vivado required for `pluto.frm`.
- **Verified:** `chronyc tracking` → stratum 1, reference `PPS`, `Leap status: Normal`, system time
  within a few hundred nanoseconds of GPS.
