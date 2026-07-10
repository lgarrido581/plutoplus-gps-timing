# LibreSDR recovery path

This page documents the recovery ladder for LibreSDR Rev.5 QSPI development.
The goal is to make normal firmware experiments recoverable without guessing at
the bench.

The current QSPI flasher, `flash_libresdr_qspi.py`, writes only the firmware/FIT
partition. It does not write FSBL, U-Boot, or the U-Boot environment. That keeps
most bad builds in the "recoverable inconvenience" category.

## Recovery ladder

Use the least invasive path that still gives you control of the board.

| Level | Use when | Recovery method |
|---|---|---|
| 0. SSH still works | Linux boots but the image is wrong or services fail | Flash a known-good `output/libre.frm` with `flash_libresdr_qspi.py` |
| 1. Linux boot fails, U-Boot/DFU works | Bad kernel, rootfs, FIT, device tree, or bitstream | Enter DFU and write a known-good firmware image |
| 2. QSPI image is bad but SD boot works | QSPI boot fails or network never appears | Boot a known-good SD image, then rewrite QSPI firmware from Linux |
| 3. Bootloader/env is damaged but JTAG works | DFU does not enumerate and SD recovery is not enough | Use the FTDI/JTAG debug port to inspect or reprogram the Zynq/QSPI |
| 4. JTAG cannot see the device | Power, cable, strap, or hardware-level issue | Stop and debug hardware before writing anything else |

## Known-good artifacts to keep

Keep these somewhere that is not inside a generated `output/` directory:

- a known-good LibreSDR SD card;
- the upstream `baseclock_cpu750_ddr525` SD image used by this repo's build;
- a known-good Tezuka/LibreSDR release image, if you use Tezuka as your
  fallback firmware;
- the last known-good `output/libre.frm` from this repo;
- if possible, a QSPI backup from your own board once QSPI boot is working.

Tezuka firmware is useful as an outside recovery reference because it actively
supports Pluto-like Zynq/AD936x clones and advertises SD-card boot support:

- <https://github.com/F5OEO/tezuka_fw>
- <https://github.com/F5OEO/tezuka_fw/releases>

## Level 0: SSH recovery from a running image

Use this when the board still boots Linux and accepts SSH.

```powershell
python flash_libresdr_qspi.py --host 192.168.1.50 --yes
```

If the candidate image is already bad, flash a previously saved known-good
`libre.frm` instead:

```powershell
python flash_libresdr_qspi.py path\to\known-good-libre.frm --host 192.168.1.50 --yes
```

The script verifies the file on the board before writing and refuses
bootloader/env-looking partitions. Do not power off while `flashcp` is running.

## Level 1: DFU recovery

Use this when Linux does not boot, but the bootloader can still enter DFU.

Validated observation so far:

- Normal Zynq USB gadget mode enumerates as Pluto-style composite USB
  `VID_0456&PID_B673` with mass storage, RNDIS, serial console, and IIO
  interfaces.
- DFU mode is confirmed from the U-Boot prompt with the OTG/device USB cable
  connected: `run dfu_sf` enumerates on Windows as `VID_0456&PID_B674`,
  friendly name `USB download gadget`.
- DFU mode is also confirmed from the physical DFU button when booting the
  rebuilt LibreSDR SD image from this repo. Holding the active-low MIO12 button
  at boot enumerates on Windows as `VID_0456&PID_B674`, friendly name
  `USB download gadget`.
- One older QSPI image observed during bring-up identified as PlutoSDR
  `v0.37-dirty` / Buildroot `2022.02.3`, not this repo's GPS timing image. It
  had no `/etc/gps-timing-board`.
- Its MTD layout is ADI/Pluto-style:
  `mtd0=qspi-fsbl-uboot`, `mtd1=qspi-uboot-env`, `mtd2=qspi-nvmfs`,
  `mtd3=qspi-linux`.
- Its U-Boot environment defines `dfu_sf` and `dfu_sf_info`, including a
  `firmware.dfu` raw target at QSPI offset `0x200000`, but `device_reboot sf`
  was observed to reboot back into Linux instead of enumerating DFU.
- Holding, or apparently even not holding, the physical button at boot was
  observed by the old QSPI U-Boot as `Button pressed: Using default
  environment`; on that old firmware the button path did not enter DFU.
- Board inspection indicates the DFU button is connected to `PS_MIO12_500`,
  pulled up to 3.3 V, and pulled down when pressed. The signal is therefore
  active-low; U-Boot should treat logic `0` as pressed.
- Observed LibreSDR Rev.5 PS MIO notes:
  - `PS_MIO9_500`: Ethernet PHY reset.
  - `PS_MIO10_500`: likely Ethernet PHY interrupt.
  - `PS_MIO11_500`: USB overcurrent.
  - `PS_MIO12_500`: DFU button, active-low.
  - `PS_MIO14_500` / `PS_MIO15_500`: FTDI debug UART TX/RX.
- If U-Boot reports `Button pressed` even when the button is not pressed, the
  likely causes are wrong MIO/GPIO selection, wrong polarity, or missing input
  configuration in the current board port.
- This repo patches the generated LibreSDR U-Boot environment from Pluto's
  GPIO14 button check to LibreSDR's active-low GPIO12 check and runs the check
  from `preboot`. The first attempted fix changed only `qspiboot`, which SD boot
  bypasses. The current fix is validated on the rebuilt SD image and in QSPI
  after deliberately flashing the QSPI-specific bootloader/environment artifacts.
- Running `run dfu_sf` at the U-Boot prompt prints `Entering DFU SF mode ...`
  and detects the W25Q256 QSPI flash. With the OTG/device USB cable connected,
  Windows enumerates `VID_0456&PID_B674` as `USB download gadget`.

Possible entry methods, inherited from the Pluto/ADI-style flow:

- hold the board's DFU button while applying power — confirmed on the rebuilt
  SD image from this repo;
- from a running system: `device_reboot sf` — observed to reboot normally on
  the older `v0.37-dirty` image;
- from a U-Boot serial console: `run dfu_sf` — reaches the DFU command path but
  requires the OTG/device USB cable and is confirmed to enumerate as
  `VID_0456&PID_B674`.

On the host, check whether the DFU device appears.

Linux:

```sh
lsusb | grep -i '0456:b674'
dfu-util --list
```

Windows:

- check Device Manager for a DFU-mode device;
- if needed, use Zadig to bind the DFU interface to WinUSB;
- run `dfu-util --list`.

ADI documents the Pluto-style DFU mode as product ID `0456:b674` and notes that
the device can enter DFU when the FIT firmware image is corrupted:

<https://wiki.analog.com/university/tools/pluto/users/firmware>

The exact LibreSDR DFU alt names should be confirmed on hardware with:

```sh
dfu-util --list
```

Do not blindly flash a bootloader alt. For normal recovery, prefer the firmware
alt that maps to the firmware/FIT region.

## Level 2: SD-card recovery

Use this when QSPI boot fails but the board can boot from SD.

1. Power off.
2. Insert a known-good LibreSDR SD card.
3. Set the board for SD boot if your hardware revision requires a strap or
   boot-mode change.
4. Boot and confirm Linux is alive over Ethernet, USB, or serial.
5. Flash a known-good `libre.frm` back to QSPI:

```powershell
python flash_libresdr_qspi.py path\to\known-good-libre.frm --host 192.168.1.50 --yes
```

6. Power off, restore QSPI boot mode, remove SD if required, and boot from QSPI.

The exact LibreSDR Rev.5 SD boot strap/jumper procedure still needs to be
validated and should be recorded here after testing.

## Level 3: FTDI/JTAG recovery

The LibreSDR debug port reportedly includes an FTDI interface wired to the Zynq
JTAG port. That is the real last-resort recovery path if QSPI bootloader state is
damaged badly enough that DFU does not enumerate.

Validated observation so far:

- The debug connector enumerates on Windows as a quad-channel FTDI device:
  `VID_0403&PID_6011` / `DEBUGCHANNEL`.
- Windows exposes serial ports on at least channels B and C as COM ports.
- Channels A through D appear as USB Serial Converter interfaces, consistent
  with an FT4232H-class debug adapter. The exact serial/JTAG channel assignment
  still needs to be mapped.
- COM6 is the Linux serial console at 115200 8N1. It prints the normal
  "Welcome to Pluto" login banner and init messages.
- With the old inherited QSPI environment, a power cycle with the DFU button
  pressed produced the same COM6 Linux login path as a normal power cycle. With
  the rebuilt LibreSDR environment, the MIO12 button path has been confirmed to
  enter DFU.
- Vivado 2022.2 Hardware Manager detects the Zynq over
  `localhost:3121/xilinx_tcf/Xilinx/DebugChannelA` as `xc7z020_1`.
- The detected device reported one VIO core in the currently loaded design.

To watch both observed serial channels while power-cycling the board:

```powershell
.\tools\watch-libresdr-debug-serial.ps1 -Ports COM5,COM6
```

First validation is non-destructive: confirm that the host can see the JTAG
chain.

Validated Vivado sequence:

```tcl
connect_hw_server -allow_non_jtag
open_hw_target
current_hw_device [get_hw_devices xc7z020_1]
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices xc7z020_1] 0]
```

With openFPGALoader, an equivalent check should be:

```sh
openFPGALoader --detect
```

With Vivado:

```text
Open Hardware Manager
Open Target
Auto Connect
Confirm the XC7Z020 appears in the hardware chain
```

Record the cable name, VID/PID, and detected device here once tested.

Do not add automated bootloader writes until this path is proven on the actual
board. Once JTAG detection is validated, the next useful additions are:

- a read-only QSPI backup procedure;
- a known-good full-QSPI restore procedure;
- an explicit `--write-bootloader` tool that is impossible to invoke by
  accident.

## Recommended pre-flight before QSPI experiments

Before using QSPI flashing on a new board:

```sh
cat /etc/gps-timing-board
cat /proc/mtd
verify_lvds.sh
```

On the host:

```sh
dfu-util --list
openFPGALoader --detect
```

Save the outputs with the board revision and firmware image hash. If a later
recovery gets weird, those boring little text files become gold.

## What is considered safe right now

Safe enough for normal development:

- boot from SD;
- validate hardware;
- flash only `output/libre.frm` to QSPI firmware/FIT;
- recover a bad firmware partition with SSH, DFU, or SD boot;
- generate QSPI-specific boot artifacts with
  `tools/finalize-libresdr-qspi.ps1`;
- back up `mtd0`/`mtd1`/`mtd2` before any bootloader/env write with
  `flash_libresdr_qspi_boot.py`;
- deliberately flash the generated QSPI `BOOT-qspi.bin` and `uboot-env.bin`
  after SD validation when the DFU button or `maxcpus=2` environment fixes are
  required.

Not yet considered validated:

- writing the SD-card `BOOT.bin` to QSPI;
- automated full-QSPI restore.

The current QSPI layout is intentionally preserved:

```text
mtd0  0x000000..0x0fffff  qspi-fsbl-uboot
mtd1  0x100000..0x11ffff  qspi-uboot-env
mtd2  0x120000..0x1fffff  qspi-nvmfs
mtd3  0x200000..end       qspi-linux / firmware FIT
```

That layout keeps bootloader, environment, NVM, and normal firmware updates
separate. The QSPI boot artifact for `mtd0` is `BOOT-qspi.bin` — FSBL + U-Boot
only — not the SD-card `BOOT.bin`.
