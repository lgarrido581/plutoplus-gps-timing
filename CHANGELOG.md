# Changelog

## v2.1.0 — ~1 s gated captures, correct arming, steadier xo discipline

Services only: the FPGA bitstream is the pinned known-good `working.bit` (fpga@1 sha256
`4c80a8c4…d87d0f`, unchanged since v2.0.4). The `pps_counter` HDL change below
(`tdd_armed`, AXI interface attributes) adds an output that Pluto+ leaves unconnected, so
this release does not re-synthesize. Pluto+ only: LibreSDR stays on v2.0.4 until it can be
smoke-tested on that board.

### xo_correct: steer on the median PPS delta, not the mean

- The Pluto+ sample clock occasionally gains tens to hundreds of counts in one second,
  inside `MAXPPM`. The 8-delta mean then stepped `xo_correction` by up to ~24 ppm the
  wrong way, and stepped back ~9 s later. Meanwhile the clock really was off, and DSN's
  1 ppm trust gate refused 45% of node1's cycles over an hour (2026-10-25).
- The loop now uses the median of its in-range deltas, so up to three glitched seconds in
  eight don't move it. The median is self-tested in `test_xo_correct.sh`.

### pluto_ctld: ~1 s gated captures, correct arming, zero-copy

- **Fixed: a gated capture could start before its PPS edge and carry that edge's label.**
  ADI's `axi_dmac` starts each segment on the first sample with its sync HIGH (a level
  test); the DMA-start latch fires on a rising edge. The old order (window live from
  configure, buffer created 0.35 s before `t0_gps`) queued the DMA into a still-open
  window whenever the window outlived the arm point. Measured with a free-running frame,
  0.5 s captures started 375 ms early and 0.9 s ones 643 ms early, with a gap where the
  DMA waited for the next window, labeled with that later edge. That hit any gated capture
  whose window (1.5× the capture + offset) was still open ~0.35 s before `t0_gps`:
  captures over ~0.43 s (with a live PPS on node1, a 0.4 s capture landed on its edge and
  a 0.6 s one started ~0.2 s early). The window output is now held low (`drive_pins`
  clear) until the buffer is queued, then released in the closed gap before the edge
  (`FRAME_POS` checked around the one-bit write); the DMA starts within 0.1 ms of the
  latched edge (0.04–0.95 s at 5, 20 and 30.72 MS/s, live PPS).
- **Fixed: a running `axi_tdd` defeated the gate.** A synced core (`sync_soft`, or any
  sync source) can't be disabled while running, so channel 1 stayed HIGH and a gated
  capture started at once. `configure_tdd` now parks such a core first (`burst_count` 1,
  then disable). See `docs/GOTCHAS.md`.
- **Fixed: the first gated capture after boot was not gated.** A disabled `axi_tdd` holds
  channel 1 at its latched polarity, whose boot default is HIGH on Pluto
  (`TDD_DEFAULT_POL 0b010`), so the RX-DMA OR stayed open until a capture had once
  restored the core. `configure_tdd` now latches channel 1 LOW first.
- **Fixed: an ungated capture after a gated one never started.** The restore left
  `axi_tdd` enabled without a sync — ARMED, every channel LOW — so the RX-DMA OR stayed
  closed until a reboot. It now holds channel 1 HIGH as after boot (channel off, polarity
  1, latched across `enable` 0 → 1), and `configure_tdd` disables the core before latching
  channel 1 LOW, since writing `enable 1` to an enabled core latches nothing.
- **Fixed: after a sample-rate change, captures used the old rate's counter.** For ~2 s
  `PPS_DELTA` counts the old rate or a mix (25.72 M for 25.00 M). The start self-check
  divided by it and flagged a correct 0.4 s capture `degraded` (−11 ms), and the
  `l_clk` multiple was detected from it. Both now use `PPS_DELTA` only within 1000 ppm of
  the nominal clock; the multiple falls back to the last one a settled count confirmed.
  New `ctl:cnt_clk_settled` says which was used.
- **Start self-check:** `ctl:start_check_ms` / `ctl:start_edge_latched` compare the latched
  edge with when the block finished, in raw counter ticks; a DMA that started early flags
  the capture `degraded`.
- **Gated captures up to ~0.97 s** (was ~0.65 s): the window is the capture + 10 ms + 4096
  samples (was 1.5× the capture).
- **The lead `t0_gps` needs no longer depends on the capture length.** The server now
  retunes and programs the window before its fresh-PPS liveness wait, so that PPS anchors
  the window. Programmed after it, the window started mid-second, and a 0.95 s capture
  needed `t0_gps` more than 2 s ahead. Now: ≥ ~1.5 s ahead at an unchanged rate, plus up
  to ~3 s when the rate changes (the AD9361 re-runs its RX analog-filter calibration,
  slowest at a few MHz: 30.72 → 2.5 MS/s took 3.0 s, 30.72 → 5 MS/s 1.5 s). A request
  that is too late is refused with how far ahead it still was.
- **One DMA block per capture.** libiio asks for four by default and the mmap path
  allocated as many full-size blocks as CMA held: a 118 MB capture took 231 MB and 690 ms
  to allocate, now 115 MB and 309 ms.
- **Zero-copy reply:** the IQ frame is sent straight from the DMA buffer (was copied
  twice); 118 MB reaches a GbE host at 45–55 MB/s. A consumer that stalls mid-reply
  has its buffer parked, not freed under zmq.
- `S66ctld` raises the kernel DMA block cap to 128 MiB (`CTL_MAX_BLOCK`) unless the U-Boot
  env sets `iio_max_block_size`.
- New metadata: `ctl:alloc_ms`, `ctl:max_block_size`, `ctl:arm_frame_pos`,
  `ctl:start_check_ms`, `ctl:start_edge_latched`, `ctl:cnt_clk_settled`.
- `ping` advertises `caps` (`held_arm`, `zero_copy`, `start_check`) and `max_block_size`,
  so a client can size and schedule captures for the build it is talking to.
- Hardware-tested on node1's Pluto+ with a live PPS: gated 0.04–0.95 s captures at 5,
  12.5 and 30.72 MS/s, most requests retuning, with ungated captures in between — 36/36
  latched their edge (`start_check_ms` +0.07 to +0.12, sample 0 within 0.1 µs of
  `t0_gps`), none `degraded`.

### pps_counter: `tdd_armed`, explicit AXI interface

- New `tdd_armed` output: high while the PPS window drives `tdd_enable`
  (`TDD_CTRL` enable and drive_pins). For designs that share the capture-start
  input with another source; Pluto+ and LibreSDR leave it unconnected.
- Explicit `X_INTERFACE_INFO` / `X_INTERFACE_PARAMETER` attributes on the AXI4-Lite
  ports. In ADI's 2023_R2 ZynqMP projects (Vivado 2023.2) module-reference inference
  took the parameter-sized ports for an interface array and built no `s_axi`
  interface, so `ad_cpu_interconnect` failed. The attributes name the interface that
  inference produces where it works: in a plain block design both versions come up
  with the same `s_axi` (AXI4-Lite, 7-bit address, same clock/reset). Metadata only.
- Synthesis: 515 → 516 LUTs on xc7z010 and xc7z020 (the `tdd_armed` AND).

## v2.0.4 — signed latch delta (anchor-label slip fix)

- **Fixed the intermittent late-capture anchor label** (+0.4967 s at a 10 MHz cnt_clk,
  +0.7484 s at 20 MHz — exactly frac(2^32/cnt_hz)): `pps_ts_latch` computed the DMA-start
  latch sub-second with an unsigned 32-bit `LATCH_COUNT - PPS_COUNT`, which wraps whenever
  the latch predates the newest PPS. The delta is now signed with a staleness gate; a
  stale/implausible latch reports no-latch and the caller falls back to the frame-grid
  snap. Services-only — the FPGA bitstream is unchanged.
- Capture metadata now exposes the raw latch registers (`gpsanchor:latch_count`,
  `latch_seq`, `latch_seq_prev`, `latch_gps_ns`, `pps_count_at_read`,
  `latch_off_signed`) so a stale-latch event is diagnosable from the consumer side.


## Unreleased — LibreSDR target

- Added `--target libresdr` alongside the backward-compatible Pluto+ default.
- Added a pinned LibreSDR v0.38 source overlay for GPS on G15/K14/J14, AXI
  UART Lite, Linux PPS, `pps_counter`, GPS-synchronized `axi_tdd`, chrony,
  sample-clock discipline, and the existing ZMQ services.
- Added a Windows Vivado 2022.2 + Docker SD-card build workflow. LibreSDR
  bring-up remains SD-only until the hardware acceptance checklist passes.
- Validated the LibreSDR sample-clock control plant on hardware at 122.88 MHz:
  `xo_correction` measured −3.047 counter ticks/Hz, or 0.3282 Hz/count. Updated
  the controller to milli-Hz gain precision and the measured rate-scaled gain.
- Fixed sub-step errors repeatedly rewriting the same `xo_correction` value and
  potentially relocking the AD936x PLL. They now report `LOCKED` without a
  write. XO limits are read from `xo_correction_available` instead of being
  hard-coded, with optional overrides from `/etc/default/xocorrect`.
- Integrated main's coincident-PPS capture path: LibreSDR now ORs the normal
  AXI-TDD streaming gate with `pps_counter/tdd_enable`, preserves its AXI-TDD v2
  sysfs fallback, and scales PPS-window counts for its measured 4× `l_clk`.
- Rebuilt the merged LibreSDR FPGA/Linux/SD artifacts with routed timing met and
  documented the complete workflow in the README. The Windows helper now retries
  a transient ADI IP-packager failure once, and `SHA256SUMS.txt` uses portable
  LF line endings so `sha256sum -c` works on Linux and Git Bash.
- Replaced LibreSDR's design-wide `Performance_Explore` workaround with explicit
  245.76 MHz source-synchronous AD9361 LVDS constraints. Post-route validation
  now rejects untimed or failing RX setup/path/skew requirements. The PPS/TDD
  gate uses registered boundary events to remove its long 32-bit range path,
  with a behavioral regression for window equivalence. `verify_lvds.sh`
  captures the hardware PRBS timing eye plus a bounded two-channel RX sample.
- Added a guarded LibreSDR QSPI promotion flow. `flash_libresdr_qspi.py` writes
  only `output/libre.frm` to the firmware/FIT MTD partition after board identity,
  MTD layout, transfer hash, and optional `verify_lvds.sh` checks. Documentation
  now separates first SD bring-up from post-validation QSPI updates.
- Began documenting the LibreSDR recovery ladder: SSH firmware recovery, DFU,
  SD-card fallback, and FTDI/JTAG last-resort access, with unvalidated
  bootloader-write paths kept out of the normal QSPI workflow.
- Patched LibreSDR's generated U-Boot environment for the board's active-low
  DFU button on `PS_MIO12_500`/GPIO12 instead of Pluto's GPIO14 check. The
  check now runs from U-Boot `preboot` so SD boot evaluates it too. The staged
  SD validator rejects a LibreSDR image that still contains the Pluto GPIO14 or
  UART1 DFU-button path.
- Added a guarded QSPI bootloader/env path: `finalize-libresdr-qspi.ps1`
  generates a partition-sized `BOOT-qspi.bin` and `uboot-env.bin`, and
  `flash_libresdr_qspi_boot.py` backs up existing QSPI boot partitions before
  any explicit bootloader/env write.
- Fixed the LibreSDR Rev.5 QSPI/USB promotion path on hardware: device trees now
  declare the board's Winbond W25Q256 flash, the legacy Linux SPI-NOR EAR helper
  handles Winbond high-address writes, USB is forced to peripheral mode, the
  generated environment keeps both Zynq-7020 CPUs online with `maxcpus=2`, and
  rootfs startup pins `iiod` to CPU0 as a guard against older single-core
  environments. A rebuilt image was flashed to QSPI and reboot-verified with
  both CPUs online, configured USB gadget, running `iiod`, and clean W25Q256
  detection.

All notable changes to this project. Versions are git tags.

## Unreleased — ZMQ capture-control API (GPS-anchored IQ)
- **`services/pluto_ctld.cpp` + `services/capture_core.c` + `services/pps_timestamp.c` +
  `services/S66ctld`:** a **WRITE** capture-control daemon (ZMQ REP **`:5562`**, `api
  dsn.pluto_zmq.ctl/1`) that tunes the AD9361 and runs a **PPS-gated, GPS-anchored** IQ capture,
  returning a SigMF pair (`meta` JSON + raw `ci16_le` IQ) stamped with the **measured** GPS time of
  sample 0 (`gpsanchor:gps_ns0`) — for sample-aligned multi-node TDOA. Two ops: `ping` (1-frame) and
  `capture` (2-frame success `[meta, iq]` / 1-frame `{"error"}`). Autostarts at boot.
- **Capture core:** `capture_core.c` is a refactor of the **validated** DSN/sdr-stack
  `device/streamer/iq_capture.c` (tune → `axi_tdd` channel-1 PPS-gated arm → one contiguous
  `iio_buffer_refill` → `pps_counter` DMA-start latch for the sample-exact anchor, with a frame-grid
  fallback), returning meta + IQ **in memory** (no files). Adds: `core:frequency` = the AD9361 LO
  **read back** (catches the silent clamp), a **`t0_gps`** wait so all nodes grab the same PPS edge,
  and the **§7 rate cap** (refuse rates whose `l_clk = interface_multiplier × rate`
  would wedge the DMA).
- **Coexistence hardening (`xo_correct.sh` + `pluto_ctld.cpp`):** writing `xo_correction`
  re-derives the AD9361 clocks and resets the sample rate — harmless when idle, but a rate
  change *mid-DMA* wedges an in-flight capture (`errno-110`). `pluto_ctld` now drops
  `/tmp/pluto_ctld.capturing` around `capture_run()`, and `xo_correct.sh` skips its correction
  while that lock is fresh (`find -mmin -2` ignores a stale lock from a crashed daemon; `/tmp`
  is tmpfs so it clears on reboot). GPS discipline resumes between captures. The ICD gains a
  **§7a "one radio owner"** section: only `pluto_ctld` may drive the chip — running a second
  host-side libiio capture path (the deprecated network-backend arming) concurrently wedges the
  DMA (a hardware limitation, reboot to clear), so pick one path. Hardware-verified: with the
  radio to itself, **13/13** back-to-back captures (10 `tdd_sync` + 4 free-run interleaved) ran
  clean; the wedge only appeared when a second process was driving the radio in parallel.
- **Integer-second fix (off-by-one):** in `tdd_sync` + `t0_gps` captures the anchor's **integer
  second** is now taken from the agreed schedule (`floor(t0_gps)`) rather than the OS clock, keeping
  the unambiguous hardware **sub-second** from `pps_counter`. chrony can lock a whole second off (gpsd
  pinning an NMEA epoch to the wrong PPS pulse at 9600 baud — phase-perfect, second wrong); since
  `tdd_sync` gates sample 0 to the `t0_gps` edge, `floor(t0_gps)` is its true second. New meta fields
  `gpsanchor:second_source` (`"t0_gps"`/`"os_clock"`) and `gpsanchor:coarse_skew_s`; a non-zero skew
  also sets `timing:health.degraded=true` (the arm may have gated the wrong physical edge — consumer
  should drop the capture). This is the firmware half of the off-by-one fix; the gpsd/chrony hardening
  that prevents the wrong lock at the source is a separate hardware-coordinated change (see ROADMAP).
- **Build:** new buildroot package `pluto-ctld` (`select`s `BR2_PACKAGE_ZEROMQ` + `BR2_PACKAGE_LIBIIO`,
  needs `libstdc++`) generated by `docker-build-inner.sh` from `services/`. Building inside buildroot
  uses the Pluto's own toolchain — sidestepping the glibc-≤2.25 cross-build the standalone binary needs.
- **Docs:** firmware ICD **`docs/PLUTO_ZMQ_CTL_ICD.md`** (mirrors DSN's `FIRMWARE_CTL_5562_SPEC.md`).
  Off-hardware validated: clean `-Wall -Wextra` compile + link against libiio/libzmq; the ZMQ/JSON
  server layer (ping both forms, 2-frame capture success, all error paths 1-frame, no REQ/REP desync)
  passed 16/16 against a stub capture core. On-hardware capture pending.

## Unreleased — ZMQ telemetry API (read-only, root-free)
- **`services/pluto_zmqd.cpp` + `services/S65zmqapi`:** a read-only **ZMQ** telemetry daemon so a
  consumer (DSN) can read the Pluto's state **without root SSH / `devmem`/`gpspipe`** — retiring the
  two read-only SSH paths (IQ capture stays as-is). **PUB `:5560`** (1 Hz JSON snapshot; absence of
  frames is the liveness signal) + **REP `:5561`** (`snapshot|timing|gps|rf|dma|ping`). Binds
  **all interfaces** (`0.0.0.0`) by default — the LAN subnet isn't knowable in advance;
  set `ZMQ_BIND=<ip>` to restrict it (read-only data on the Pluto's local links; not on the
  tailnet by design). **Read-only by construction**; capture/retune are v2 on a separate authed socket.
- **Blocks:** `timing` (pps_counter via `/dev/mem` mmap + `xo_ppm` from `xocorrect.log`) and `gps`
  (persistent gpsd client) reuse the **exact `dsn.health/1` field names** (DSN's parser is transport-
  agnostic); plus new `rf` (actual `ad9361-phy` LO/rate/bw/gain — catches the silent LO clamp) and
  best-effort `dma` (kernel-log scan for the errno-110 RX wedge).
- **Build:** first cross-compiled binary in the repo — a buildroot package `pluto-zmqd` (`select`s
  `BR2_PACKAGE_ZEROMQ`, needs `libstdc++`) generated by `docker-build-inner.sh` from `services/`
  (mounted via `docker-run.sh`). Autostarts at boot (`S65zmqapi`). Debug with `pluto_zmqd --print`.
- **Docs:** design overview **`docs/PLUTO_ZMQ_API.md`** + formal **`docs/PLUTO_ZMQ_ICD.md`**
  (per-field data dictionary, message catalog, framing/error/versioning) — conformance-tested
  54/54 against the built binary.
- **Validated on hardware:** flashed to a Pluto+ at a 3-D fix; REP `ping`/`snapshot` + the 1 Hz
  PUB heartbeat exercised over TCP from a LAN client. Live `timing` (`pps_present`, advancing
  `pps_seq`, `xo_ppm`, `cnt_clk_hz`), real `gps` + `rf`. The run caught two fixes: the bind
  default (`0.0.0.0` instead of a hardcoded subnet) and `rx_gain_db` now emitted as a number
  (the chip reports `"71.000000 dB"`; the daemon strips the unit).

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
- **Metrics pipeline is now rate-independent** (`hdl/pps_counter/metrics/`): the capture scripts
  auto-derive `NOMINAL` (sysfs `sample_rate` × measured `l_clk` multiple) and emit a `# nominal=`
  header; `analyze.py`/`compare.py` read that header, else auto-detect from the data, with a CLI
  override. Fixes the **2R2T footgun** where `capture_and_correct.sh` defaulted `NOMINAL=30720000` but
  the latch counts at 61.44 MHz in `mode=2r2t` (silently wrong ppm unless a human passed
  `NOMINAL=61440000`). `read_counter.py` already reported the measured rate, so it needed no change.
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
  `pps_tick`. **Validated on hardware** (`PASS`, `FRAME_SEQ` 0..~100, `axi_tdd CONTROL=0xB`). Software
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
