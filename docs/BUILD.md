# Build details

This document describes the default Pluto+ target. The separate LibreSDR
Zynq-7020 target uses native Windows Vivado 2022.2 plus Docker packaging; see
[`LIBRESDR.md`](LIBRESDR.md).

The firmware is built **entirely in Docker** on top of
[`sardylan/plutoplus`](https://github.com/sardylan/plutoplus) `fw-0.39`. See the top-level
[`README.md`](../README.md) for the quick-start build/flash commands; this doc covers prerequisites,
the two build variants, and what the build actually changes.

## Prerequisites

- **Docker** (Desktop on Windows/macOS, or Engine on Linux).
- A POSIX shell to run the `.sh` scripts. On **Windows** use **WSL2** or **Git Bash**.
- ~5 GB free disk + network (the build downloads the kernel, buildroot packages, an ARM
  cross-toolchain, and the v0.39 FPGA `system_top.xsa`).
- **Vivado** *only* to re-synthesize the bitstream (a gateware change) —
  **2023.2** to synth in-container (`--vivado`), **or any compatible version** if you pre-synth the bit
  yourself and inject it (`--prebuilt-bit`, see below). Not needed for the default build, which reuses
  `output/working.bit` (see below for where that file comes from).

## Build variants

| Command | Produces |
|---|---|
| `bash docker-run.sh` | **Fleet `pluto.frm`.** Reuses the pinned known-good `output/working.bit` (a local file, not in git — see below) (coincident-capture / FPGA `pps_counter`, F20 hardware PPS latch) **+** its `PPS_HWLATCH=1` services (`S70xocorrect` `xo_correction`). No Vivado. Exactly equivalent to `--prebuilt-bit output/working.bit --hwlatch`. |
| `bash docker-run.sh --vivado <XilinxPath> --hwlatch` | Same firmware, but **re-synthesizes** the bitstream from HDL — use this for a gateware change, then refresh `output/working.bit` + `boards/plutoplus/fpga.sha256pin`. |
| `bash docker-run.sh --gpio-test …` | I/O-voltage test build → `pluto-gpiotest.frm`. |

> A bare run **never** silently synthesizes or downloads a bit: it reuses `output/working.bit`, or
> **refuses to build** if that's missing. Every build prints `fpga@1 sha256`; a build that reuses a
> bitstream (`--prebuilt-bit`, including the bare default) fails if it ≠
> `boards/plutoplus/fpga.sha256pin`. A `--vivado` build is not checked against the pin (a fresh synth
> has a new hash). This is the guardrail against the class of bug where a stock
> bit with **no `pps_counter`** ships and the radio boots `pps=N` / GPS-untrusted for no obvious
> reason. `output/working.bit` = the coincident-capture bit, sha256 `4c80a8c4…d87d0f`.

### Where `output/working.bit` comes from

`output/working.bit` is **not in git**: `.gitignore` excludes `output/` and `*.bit`, so a fresh
clone doesn't have it and a bare `docker-run.sh` stops with "no bitstream source". It is the
bitstream carried in the `fpga@1` image of the released Pluto+ `pluto.frm` — per the
[CHANGELOG](../CHANGELOG.md), unchanged since v2.0.4 (v2.1.0 and v2.2.0 reuse it). No script in this
repo extracts it; if you do, never use the `fdt` pip lib (see the warning below), and check
`sha256sum` against `boards/plutoplus/fpga.sha256pin` — the reuse build rejects a mismatch anyway.
Without it, a `--vivado` build produces a *new* bitstream, not the pinned one.

`prebuilt/system_top_hwlatch.bit` is **not** a substitute: it is an older bitstream whose sha256
does not match the pin, so a reuse build with it fails the pin gate (see
[`prebuilt/README.md`](../prebuilt/README.md)).

> **Open:** whether to publish the pinned bitstream (e.g. as a release asset) so a fresh clone can
> build without extracting it is undecided.

The equivalent explicit default is `bash docker-run.sh --target plutoplus`.
`--target libresdr` selects a separate pinned source cache and never reuses or
modifies the Pluto+ source volume.

### Supplying the FPGA bitstream — pick ONE (this is the step people trip on)

The default build reuses the pinned `output/working.bit`. A gateware change (or the `--gpio-test`
variant) needs a newly built `system_top.bit`. There are **two** ways to give the build one — they
produce the same firmware:

- **(A) In-container synth — `--vivado <XilinxPath>`.** Mounts your Vivado into the container at the
  **same absolute path** and runs synth+impl inside the build. Requires **Vivado 2023.2** (the version
  the sardylan HDL targets). One self-contained command:
  ```sh
  bash docker-run.sh --vivado /path/to/Xilinx --hwlatch
  ```
- **(B) Pre-synth + inject — `--prebuilt-bit <system_top.bit>`.** Synthesize `system_top.bit`
  **yourself first** (with any compatible Vivado — do this if you don't have 2023.2, or want a faster
  bake), then hand the `.bit` to the build; **no Vivado runs in the container**:
  ```sh
  bash docker-run.sh --prebuilt-bit /path/to/system_top.bit --hwlatch
  ```
  This is the reuse path, so the pin gate applies: a new bit fails it until
  `boards/plutoplus/fpga.sha256pin` holds the new bit's sha256.

Either way the bit is repackaged into `pluto.frm`; the stock `boot.frm` is reused unchanged (PL-only
"Option B", so no Vitis/FSBL). **If you change the FPGA** — `hdl/pps_counter/*` or the block-design
patch in `docker-build-inner.sh` — you must regenerate the bit by **either** path; a stale
`--prebuilt-bit` will silently ship the old logic.

> ⚠️ **Only inject the pinned bitstream (or one you just synthesized).** A `--prebuilt-bit` build
> produced the broken v2.0.1 `pluto.frm`: the injected `.bit` was a **truncated 241 KB extract of the
> real 964 KB bitstream** (the `fdt` Python lib silently truncates large `data` props when extracting),
> so the PL couldn't configure → boot hang → brick. This is the v1.5 brick repeated. **Never extract a
> bitstream with the `fdt` pip lib.** The build now refuses a suspiciously small `.bit`,
> `test/check_frm_images.sh` fails any `.frm` whose `fpga@1` is too small, and the reuse path fails
> unless `fpga@1` matches `boards/plutoplus/fpga.sha256pin`. Releases are built this way — reusing the
> pinned `output/working.bit` (v2.1.0, v2.2.0); a `--vivado` re-synthesis is for gateware changes, and
> then the pin must be updated. See [`../RELEASING.md`](../RELEASING.md).

**Base vs bootloader:** the build produces **`pluto.frm` only**, never `boot.frm` (FSBL + bitstream +
U-Boot). For a normal update of a working device, `pluto.frm` is all you need. To flash a
fresh/bricked device's bootloader you need a Pluto+ `boot.frm` from a prebuilt release — see
[`RECOVERY.md`](../RECOVERY.md).

The build runs unattended and caches source in a Docker named volume (`gps-timing-plutoplus-src-cache`; LibreSDR uses
`gps-timing-libresdr-src-cache`), so
re-runs are fast. (The host `tee` pipeline can report a non-zero exit even on success — trust the
`Done.` line and `output/pluto.frm`.)

## Repository layout

```
.
├── Dockerfile              # Build environment (Ubuntu + cross tools + deps)
├── docker-run.sh           # Builds the image and runs the build (entry point)
├── docker-build-inner.sh   # Runs INSIDE the container: clone, patch, configure, build
├── hdl/pps_counter/        # FPGA GPS-timing counter IP, discipline loop, metrics
├── tdoa/                   # GPS-timestamped IQ capture + TDOA roadmap
├── docs/                   # WIRING, NTP, GOTCHAS, BUILD, NETWORK
├── README.md
├── RECOVERY.md             # Un-brick / first-time bootloader flashing via SD boot
├── CHANGELOG.md
└── output/                 # (gitignored) firmware images land here after a build
```

## What the build customizes on top of `fw-0.39`

`docker-build-inner.sh` clones `sardylan/plutoplus` (`fw-0.39`), applies the upstream patches, then:

**Kernel** (`zynq_pluto_defconfig` + `zynq-pluto-sdr-revc.dts`)
- Enables `CONFIG_PPS` + `CONFIG_PPS_CLIENT_GPIO`; removes the UART1 *early-debug* console options.
- Adds a `pps-gpio` node on **MIO9**.

**Buildroot** (`zynq_pluto_defconfig`, applied idempotently)
- `BR2_PACKAGE_GPSD_DEVICES="/dev/ttyPS0"` (stock default `/dev/ttyS1` doesn't exist)
- `BR2_PACKAGE_CHRONY=y` + `BR2_PACKAGE_PPS_TOOLS=y` → chrony compiles the **PPS refclock**
  (`HAVE_SYS_TIMEPPS_H`) and you get `ppstest`
- `BR2_PACKAGE_NCURSES=y` → gpsd also builds `gpsmon` + `cgps`
- `BR2_TARGET_GENERIC_GETTY_PORT=""` + a post-build script that deletes the serial getty line (so
  nothing competes with gpsd on `ttyPS0`)
- `BR2_ROOTFS_OVERLAY="board/pluto/gps-overlay"` shipping:
  - `/etc/chrony.conf` (GPS via gpsd SHM + PPS via `/dev/pps0`)
  - a custom `/etc/init.d/S50gpsd` that forces **9600** and runs `gpsd -n -b`
  - `/etc/init.d/S30bootdelay` that sets U-Boot `bootdelay=-2`
  - *(`--hwlatch` only)* `xo_correct.sh` + `/etc/init.d/S70xocorrect` (GPS sample-clock discipline)

**FPGA** (`--hwlatch` / `--gpio-test`): integrates `pps_counter` into the Pluto block design and adds
the F20 PPS pin constraint — see [`hdl/pps_counter/README.md`](../hdl/pps_counter/README.md).

**Misc**
- Patches the `plutosdr-fw` Makefile so `git describe` has a `v0.39` fallback (shallow clone).
- Forces `chrony`/`gpsd` to rebuild so the config changes take effect.
