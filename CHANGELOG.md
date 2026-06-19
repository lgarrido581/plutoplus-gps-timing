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
  script that waits for a chrony PPS lock first (no seed correction — converges from boot).
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
