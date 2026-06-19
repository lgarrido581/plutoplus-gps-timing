# Build details

The firmware is built **entirely in Docker** on top of
[`sardylan/plutoplus`](https://github.com/sardylan/plutoplus) `fw-0.39`. See the top-level
[`README.md`](../README.md) for the quick-start build/flash commands; this doc covers prerequisites,
the two build variants, and what the build actually changes.

## Prerequisites

- **Docker** (Desktop on Windows/macOS, or Engine on Linux).
- A POSIX shell to run the `.sh` scripts. On **Windows** use **WSL2** or **Git Bash**.
- ~5 GB free disk + network (the build downloads the kernel, buildroot packages, an ARM
  cross-toolchain, and the v0.39 FPGA `system_top.xsa`).
- **Vivado 2023.2** *only* for the `--hwlatch` / FPGA-counter variant (it rebuilds the bitstream).
  Not needed for the base firmware.

## Two variants

| Command | Produces |
|---|---|
| `bash docker-run.sh` | **Base** `pluto.frm` (GPS system-time firmware). No Vivado. |
| `bash docker-run.sh --vivado <XilinxPath> --hwlatch` | Base **+ FPGA `pps_counter`** with the F20 hardware PPS latch and the auto-started `xo_correction` discipline. |
| `bash docker-run.sh --vivado <XilinxPath> --gpio-test` | I/O-voltage test build → `pluto-gpiotest.frm` |

The Vivado path is mounted into the container at the **same absolute path** and rebuilds the FPGA
bitstream, which is repackaged into `pluto.frm`. The stock `boot.frm` is reused unchanged (PL-only
"Option B" design), so no Vitis/FSBL is needed.

**No-Vivado caveat:** without Vivado the build produces **`pluto.frm` only**, not `boot.frm` (the
FSBL + bitstream + U-Boot bootloader). For a normal firmware update of a working device, `pluto.frm`
is all you need. To flash a fresh/bricked device's bootloader you need a Pluto+ `boot.frm` from a
prebuilt release — see [`RECOVERY.md`](../RECOVERY.md).

The build runs unattended and caches source in a Docker named volume (`plutoplus-src-cache`), so
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
