# PlutoPlus GPS Timing Firmware

Custom firmware for the **Pluto+ (ADALM-Pluto+ / "Pluto SDR+" clone, Zynq‑7010)** that adds
**GPS‑disciplined time**:

- **PPS** (pulse‑per‑second) on **MIO9** via the kernel `pps-gpio` driver → `/dev/pps0`
- **GPS NMEA** on **UART1** (MIO12/MIO13) → `/dev/ttyPS0`
- **gpsd** to parse NMEA + **chrony** to discipline the system clock from GPS (coarse) and PPS (precise)

It is built **entirely in Docker** on top of [`sardylan/plutoplus`](https://github.com/sardylan/plutoplus)
**`fw-0.39`** — no local Xilinx/Vivado install is required to produce a flashable firmware image.

> ✅ **Status: verified working.** Achieves a **stratum-1, PPS-disciplined** system clock —
> `chronyc tracking` reports `Leap status: Normal`, reference ID `PPS`, with system time within a
> few hundred nanoseconds of GPS once the receiver holds a fix.

**Docs:** [Wiring](docs/WIRING.md) · [Recovery / un-brick](RECOVERY.md) · [FPGA timing counter](hdl/pps_counter/README.md) · [TDOA tooling](tdoa/README.md) · [Changelog](CHANGELOG.md)

> ⚠️ **Read [`RECOVERY.md`](RECOVERY.md) before you flash.** The Pluto+ QSPI flash is *unprotected*
> and is easily corrupted by an interrupted write. Recovery is straightforward via SD‑card boot, but
> you want to know the procedure *before* you need it.

---

## What's baked into the image

| Capability | Detail |
|---|---|
| PPS input | `pps-gpio` on **MIO9**, `CONFIG_PPS` + `CONFIG_PPS_CLIENT_GPIO` → `/dev/pps0` |
| GPS serial | **UART1** (MIO12 TX / MIO13 RX) enabled → **`/dev/ttyPS0`** (see note below) |
| gpsd | auto‑starts on `/dev/ttyPS0`, forced **9600 baud**, `-n -b` (continuous poll, read‑only) |
| chrony | auto‑starts with PPS **refclock compiled in** (via `pps-tools`/`timepps.h`) + `/etc/chrony.conf` |
| NTP server | serves **stratum‑1 GPS time to your LAN** (chrony `allow`, RFC1918 by default; only serves once PPS‑locked) |
| Tools | `ppstest`, `gpsmon`, `cgps`, `gpspipe` for diagnostics |
| Console freed | login getty removed from `ttyPS0` so it doesn't fight gpsd |
| Boot‑safe | `bootdelay=-2` auto‑set so the GPS NMEA stream can't abort U‑Boot autoboot |

> **Why `/dev/ttyPS0` and not `ttyPS1`?** On this board UART0 is disabled and UART1 owns the
> `serial0` device‑tree alias, so Linux enumerates UART1 as `ttyPS0`. The NMEA port is `/dev/ttyPS0`.

---

## Hardware required

- **Pluto+ board** (V2 / 3V3 levels). SD‑card slot + Ethernet ⇒ it's a Pluto+, not a stock ADALM‑Pluto.
- **GPS module** with a 3V3 UART (NMEA) and a **PPS** output. Tested with a u‑blox **NEO‑6M**;
  a multi‑GNSS **NEO‑M8N** or a timing‑grade **NEO‑M8T** is recommended (see *Antenna & reception*).
- **Active GPS antenna** — ideally with a **long (3–5 m) cable** so it can sit at a window / outside,
  **away from the Pluto** (the SDR desenses the GPS L1 band badly at close range).
- A **microSD card** (FAT32) for first‑time bootloader flashing / recovery — see `RECOVERY.md`.

---

## Repository layout

```
.
├── Dockerfile              # Build environment (Ubuntu + cross tools + deps)
├── docker-run.sh           # Builds the image and runs the build (entry point)
├── docker-build-inner.sh   # Runs INSIDE the container: clone, patch, configure, build
├── hdl/pps_counter/        # FPGA GPS-timing counter IP + on-device tools (see below)
├── tdoa/                   # GPS-timestamped IQ capture + TDOA roadmap
├── docs/WIRING.md          # GPS module wiring detail
├── case/                   # 3D-printable GPS antenna bracket + BOM
├── README.md
├── RECOVERY.md             # Un-brick / first-time bootloader flashing via SD boot
├── CHANGELOG.md
├── LICENSE
└── output/                 # (gitignored) firmware images land here after a build
```

---

## Prerequisites

- **Docker** (Desktop on Windows/macOS, or Engine on Linux).
- A POSIX shell to run the `.sh` scripts. On **Windows** use **WSL2** or **Git Bash**.
- ~5 GB free disk and a network connection (the build downloads the kernel, buildroot packages,
  an ARM cross‑toolchain, and the v0.39 FPGA `system_top.xsa`).

No Vivado/Xilinx tools are needed for `pluto.frm`. (Vivado is only needed to also produce
`boot.frm`, the bootloader — see *Flashing*.)

---

## Quick start (build)

```bash
git clone https://github.com/<you>/plutoplus-gps-timing.git
cd plutoplus-gps-timing
bash docker-run.sh
```

When it finishes you'll have (in `./output/`):

| File | What it is |
|---|---|
| `pluto.frm` | **The firmware** (kernel + device tree + rootfs + FPGA bitstream) — flash this |
| `pluto.dfu` | Same image in DFU format (for `dfu-util`) |
| `plutosdr-fw-v0.39*.zip` | Packaged release bundle |

> The build runs unattended and caches the source in a Docker named volume
> (`plutoplus-src-cache`), so re‑runs are much faster. The host wrapper may print a non‑zero exit
> code from the `tee` pipeline even on success — the real status is the `Done.` line in the log and
> the presence of `output/pluto.frm`.

### No‑Vivado caveat (important)

Without Vivado the build produces **`pluto.frm` only**, *not* `boot.frm` (the FSBL + bitstream +
U‑Boot bootloader). For a **normal firmware update** of a working device, `pluto.frm` is all you
need. To **flash a fresh/bricked device's bootloader**, you need a Pluto+ `boot.frm` from a prebuilt
release — see [`RECOVERY.md`](RECOVERY.md).

---

## Flashing (normal update of a working device)

Pick either method. **Never power off mid‑write** — the unprotected QSPI corrupts easily.

**A) From Linux on the device (SSH/serial):**
```bash
scp output/pluto.frm root@pluto.local:/root/     # password: analog
ssh root@pluto.local
update_frm.sh ./pluto.frm
reboot
```

**B) Mass storage:** copy `pluto.frm` onto the `PlutoSDR` USB drive, **safely eject**, wait for the
LED activity to finish **+ ~30 s**, then it reboots itself.

First boot after a fresh environment: the GPS NMEA can abort U‑Boot autoboot (see below). Either
boot once with the **GPS TX (MIO13) disconnected**, or set `bootdelay` manually (see *Gotchas*).

---

## GPS hardware wiring

Wire the GPS module to the Pluto+ expansion header (map these **MIO numbers** to your board's
header pinout):

| GPS pin | → Pluto+ | Notes |
|---|---|---|
| **PPS** | **MIO9** | `pps-gpio`, rising edge → `/dev/pps0` |
| **TX** (GPS out) | **MIO13** | UART1 **RX** — this carries NMEA into the Pluto |
| **RX** (GPS in) | **MIO12** | UART1 **TX** — optional (only needed to configure the GPS) |
| **GND** | **GND** | must be common |
| **VCC** | **3V3** | a real power rail, **not** an MIO pin |

> TX/RX are the #1 mistake: **GPS TX must go to MIO13.** If you see only line noise / nothing,
> swap TX↔RX.

---

## Verifying GPS timing

SSH in (`ssh root@pluto.local`, password `analog`) once booted with the GPS connected:

```sh
# services up automatically?
ps -ef | grep -E 'gpsd|chronyd' | grep -v grep   # gpsd on /dev/ttyPS0, chronyd running
ls -l /dev/pps0 /dev/ttyPS0                        # both present

# live GPS view (needs a sky-view fix)
gpsmon /dev/ttyPS0          # satellites, SNR bars, fix status (Ctrl-C to exit)
cgps -s                     # simpler fix/sat summary
cat /dev/ttyPS0 | grep -m1 GSV | cut -d, -f4   # satellites in view (field 4)

# once it has a fix (GGA shows ,1,NN,):
ppstest /dev/pps0           # assert events ~1/sec
chronyc sources -v          # GPS + PPS refclocks; PPS gets '*' when locked
chronyc tracking            # Leap status: Normal — disciplining the clock
```

---

## Using the Pluto as an NTP server

Once flashed and **GPS-locked** (`chronyc tracking` → `Leap status: Normal`), the Pluto serves NTP
to clients in the `allow` ranges in `/etc/chrony.conf` (private IPv4 + IPv6 link-local `fe80::/10`).
It will **not** serve before it's locked (won't hand out bad time).

**On the Pluto — confirm it's serving / see clients:**
```sh
chronyc tracking            # Leap status: Normal = serving GPS time
chronyc clients             # hosts that have queried it
netstat -anu | grep ':123'  # confirms it's listening on UDP 123
chronyc allow all           # runtime-only test widen (resets on reboot)
```

**Query it from a client:**
```sh
# Windows:
w32tm /stripchart /computer:pluto.local  /samples:3   # over IPv6 (eth0)
w32tm /stripchart /computer:192.168.2.1  /samples:3   # over USB IPv4
# Linux/macOS:
sntp pluto.local            # or: ntpdate -q 192.168.2.1
```

**Make a client actually sync to it:**
```bat
:: Windows (elevated cmd) — ,0x8 forces client mode
w32tm /config /manualpeerlist:"pluto.local,0x8" /syncfromflags:manual /update
net stop w32time && net start w32time
w32tm /resync
w32tm /query /status        :: Source should show pluto.local
```
```sh
# Linux chrony client: add to /etc/chrony.conf, then restart chrony
server pluto.local iburst
```

**Networking notes**
- The `allow` list covers private IPv4 + IPv6 link-local. Queries that resolve to the Pluto's
  `fe80::` address (common via `pluto.local`) are allowed by `fe80::/10`. (An IPv4-only allow list
  silently drops IPv6 queries — that was the v1.1→v1.2 fix.)
- For **LAN-wide** serving, give `eth0` a routable IPv4 (DHCP from your router or a static IP). Out
  of the box `eth0` only has an IPv6 link-local + a `169.254` APIPA address, so it isn't reachable
  by a normal LAN IPv4 until configured.

## How it works — what the build customizes on top of `fw-0.39`

`docker-build-inner.sh` clones `sardylan/plutoplus` (`fw-0.39`), applies the upstream patches, then:

**Kernel** (`zynq_pluto_defconfig` + `zynq-pluto-sdr-revc.dts`)
- Enables `CONFIG_PPS` + `CONFIG_PPS_CLIENT_GPIO`; removes the UART1 *early‑debug* console options.
- Adds a `pps-gpio` node on **MIO9**.

**Buildroot** (`zynq_pluto_defconfig`, applied idempotently)
- `BR2_PACKAGE_GPSD_DEVICES="/dev/ttyPS0"` (stock default `/dev/ttyS1` doesn't exist)
- `BR2_PACKAGE_CHRONY=y` + `BR2_PACKAGE_PPS_TOOLS=y` → chrony compiles the **PPS refclock**
  (`HAVE_SYS_TIMEPPS_H`) and you get `ppstest`
- `BR2_PACKAGE_NCURSES=y` → gpsd also builds `gpsmon` + `cgps`
- `BR2_TARGET_GENERIC_GETTY_PORT=""` + a post‑build script that deletes the serial getty line
  (so nothing competes with gpsd on `ttyPS0`)
- `BR2_ROOTFS_OVERLAY="board/pluto/gps-overlay"` shipping:
  - `/etc/chrony.conf` (GPS via gpsd SHM + PPS via `/dev/pps0`)
  - a custom `/etc/init.d/S50gpsd` that forces **9600** and runs `gpsd -n -b`
  - `/etc/init.d/S30bootdelay` that sets U‑Boot `bootdelay=-2`

**Misc**
- Patches the `plutosdr-fw` Makefile so `git describe` has a `v0.39` fallback (shallow clone).
- Forces `chrony`/`gpsd` to rebuild so the config changes take effect.

---

## GPS‑disciplined *sample* timing — FPGA counter (advanced / experimental)

The sections above give GPS‑disciplined **system** time. For **sample‑accurate** timing
(`xo_correction` clock discipline and **TDOA**), this repo can also build a custom FPGA peripheral,
**`pps_counter`** — a free‑running counter on the AD936x **sample clock**, exposed over AXI‑Lite at
**`0x7C460000`**, with an optional hardware **PPS latch**. Full design + register map in
[`hdl/pps_counter/README.md`](hdl/pps_counter/README.md).

This path **requires Vivado 2023.2** (mounted into the container) because it rebuilds the FPGA
bitstream. The bitstream is repackaged into `pluto.frm`; the stock `boot.frm` is reused unchanged
(PL‑only design), so no Vitis/FSBL is needed (“Option B” build).

```bash
# build pluto.frm WITH the counter (mount your Vivado install at its real path):
bash docker-run.sh --vivado /home/you/Xilinx
bash docker-run.sh --vivado /home/you/Xilinx --hwlatch     # + F20 hardware PPS latch (ns)
bash docker-run.sh --vivado /home/you/Xilinx --gpio-test   # I/O voltage test -> pluto-gpiotest.frm
```

Read it on the device with **`devmem`** (no Python needed):
```sh
devmem 0x7C460000 32     # 0x50505343 ("PPSC") = counter present
devmem 0x7C46000C 32     # LIVE_COUNT — increments; sample-clock count for xo_correction
```

> **Status: validated on hardware.** The `--hwlatch` build is flashed and working: the hardware PPS
> latch captures, GPS locks (stratum‑1), and RF still tunes despite the **~‑2.5 ns setup violation in
> AD9361 *config‑write* paths** (near‑full xc7z010‑**1**; not the datapath, not the counter) — the
> build‑flow override is safe in practice. A userspace loop ([`xo_correct.sh`](hdl/pps_counter/xo_correct.sh))
> disciplines the sample clock to GPS, **−7.77 ppm → +0.02 ppm**; before/after metrics and figures are
> in [`hdl/pps_counter/metrics/`](hdl/pps_counter/metrics/).
>
> **I/O levels (Pluto+ V2):** PL banks (incl. **F20/F19**) are **1.8 V** (AD936x `VDD_INTERFACE`);
> PS MIO bank 500 (incl. **MIO9**) is **3.3 V**. A 3.3 V GPS PPS is fine on MIO9 but must be
> level‑shifted to 1.8 V for the F20 hardware latch.

---

## ⚠️ Gotchas (hard‑won)

- **U‑Boot autoboot vs GPS.** UART1 (MIO13) is also U‑Boot's console input. The GPS NMEA stream
  makes U‑Boot think a key was pressed and it **stops at the prompt instead of booting**. Fix:
  `bootdelay=-2` (boot immediately, ignore console input). The `S30bootdelay` init script applies
  this automatically — but it can only run *after* a successful boot, so the **first** boot on a
  fresh env must have the **GPS TX (MIO13) disconnected**, or set it by hand:
  ```sh
  printf 'bootdelay -2\n' > /tmp/bd && fw_setenv -s /tmp/bd && fw_printenv bootdelay
  ```
  (Use script mode — `fw_setenv bootdelay -2` fails because it parses `-2` as a flag.) This setting
  lives in the QSPI env and survives `pluto.frm` re‑flashes.

- **GPS baud.** u‑blox modules default to **9600**; the kernel leaves `ttyPS0` at the console's
  115200. The shipped `S50gpsd` forces 9600. If reading manually, `stty -F /dev/ttyPS0 9600 raw`.

- **Antenna & reception.** The Pluto is an SDR — keep the GPS antenna **well away** from the board
  (use a long‑cable active antenna at a window/outside). A NEO‑6M sitting next to the Pluto often
  sees only 1–2 satellites and never locks. You need **≥4** sats (3 for a 2D fix). Multi‑GNSS
  (NEO‑M8N) sees far more; a timing‑grade NEO‑M8T can hold time on a single satellite after
  survey‑in.

- **Spurious build exit code.** `docker-run.sh`'s `tee` pipeline can report a non‑zero code even on
  a successful build. Trust the `Done.` line and `output/pluto.frm`.

---

## Recovery / first‑time bootloader flashing

If the device won't boot (e.g. an interrupted flash corrupted the QSPI), see **[`RECOVERY.md`](RECOVERY.md)**
for the SD‑card boot + `boot.frm` procedure.

---

## Credits

- [`sardylan/plutoplus`](https://github.com/sardylan/plutoplus) — Pluto+ firmware base (fw‑0.39)
- [Analog Devices `plutosdr-fw`](https://github.com/analogdevicesinc/plutosdr-fw) — upstream Pluto firmware
- The Pluto+ community FAQ thread for the unprotected‑SPI recovery method

## License

The glue scripts and docs in this repository are released under the [MIT License](LICENSE). The
firmware components built by this project (Linux kernel, U‑Boot, Buildroot packages, etc.) retain
their own respective licenses (GPL, etc.).
