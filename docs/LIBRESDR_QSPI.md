# LibreSDR QSPI flashing

LibreSDR QSPI flashing is a promotion step for an image that already passed SD
bring-up. It avoids repeated SD-card writes after the board is known good.

The normal firmware-promotion workflow writes only the firmware/FIT partition.
It does not write the FSBL, U-Boot, U-Boot environment, spare partition, or NVM
storage. A separate, explicit optional workflow below can update the
QSPI-specific FSBL/U-Boot and environment after making backups.

## When to use it

Use QSPI flashing after all of these are true:

- the LibreSDR boots this repo's image from SD;
- `cat /etc/gps-timing-board` prints `BOARD=libresdr`;
- the hardware acceptance checklist in [`LIBRESDR.md`](LIBRESDR.md) passes;
- you have kept a known-good SD card for recovery.

Do not use this as the first LibreSDR bring-up path. A bad bitstream, device
tree, rootfs, or AD9361 interface issue is much easier to recover from on SD.

## Build the image

Build the LibreSDR target normally:

```sh
bash docker-run.sh --target libresdr --prepare-hdl
```

```powershell
.\tools\build-libresdr-hdl.ps1 `
  -VivadoRoot C:\Xilinx `
  -MakeExe C:\Xilinx\Vitis_HLS\2022.2\tps\win64\msys64\mingw64\bin\make.exe
```

```sh
bash docker-run.sh --target libresdr \
  --prebuilt-bit output/libresdr-hdl/system_top.bit
```

The QSPI firmware image is:

```text
output/libre.frm
```

The SD files in `output/libresdr-sd/` are still useful for first boot and
recovery.

## Flash the firmware partition over SSH

Install the host dependency once:

```powershell
python -m pip install paramiko
```

Then flash the validated image:

```powershell
python flash_libresdr_qspi.py --host 192.168.1.50 --run-lvds-test --yes
```

If the board has already passed `verify_lvds.sh` during this boot and you do
not want to rerun the PRBS eye check:

```powershell
python flash_libresdr_qspi.py --host 192.168.1.50 --yes
```

This is the normal update path after the board is already booting a validated
LibreSDR image. On LibreSDR this script refuses to run if the kernel reports the
suspicious
`w25q256`/`n25q256a` SPI-NOR mismatch observed on Rev.5 boards, or the related
EAR-register warning. That mismatch can erase `/dev/mtd3` correctly but corrupt
data during Linux MTD writes. Keep the guard enabled unless the running
kernel/device tree has been fixed and the write/readback path has been
validated.

New builds apply two LibreSDR W25Q256 fixes:

1. the Linux and U-Boot device trees declare the actual Winbond W25Q256 QSPI
   NOR instead of inheriting Micron N25Q compatibles;
2. the Linux SPI-NOR EAR helper is patched so the Zynq-7000 QSPI path can use
   Winbond RDEAR/WREAR when accessing addresses above 16 MiB.

New builds also force the LibreSDR USB controller to peripheral/gadget mode
rather than OTG role switching. If the controller lands in host role, configfs
gadget binding fails with `configfs-gadget ci_hdrc.0: failed to start
composite_gadget: -19` and Windows sees no Pluto-style USB device. The
LibreSDR U-Boot environment is also forced back to `maxcpus=2`, matching the
Zynq-7020. A temporary regression to the inherited Pluto `maxcpus=1` setting
left only CPU0 online; the stock gadget script pinned `iiod` to CPU1, so the
FunctionFS IIO endpoint never became ready and produced the same `-19`
gadget-bind failure. The rootfs now pins `iiod` to CPU0 as a robustness guard.
The LibreSDR environment also removes the leftover `PlutoRevA` conditional from
the DFU-button path and preserves the known-good `cpuidle.off=1` and
`uio_pdrv_genirq.of_id=uio_pdrv_genirq` bootargs from the original LibreSDR
environment.

After booting a rebuilt SD image, this check must not print `expected n25q256a`
or `failed to read ear reg`:

```sh
dmesg | grep -E 'spi-nor|w25q256|n25q|ear'
```

Only retry the Linux-MTD flasher after that boot log is clean.

The script:

1. connects as `root` with password `analog` by default;
2. requires `/etc/gps-timing-board` to identify the image as LibreSDR;
3. parses `/proc/mtd` and selects the firmware partition, normally `/dev/mtd3`;
4. copies `output/libre.frm` to `/tmp`;
5. verifies the on-board MD5 before touching flash;
6. runs `flashcp -v` so erase/write/verify are handled by the board;
7. reboots and performs a quick IIO/PPS smoke check.

Use `--no-reboot` if you want to flash now and reboot later.

## Alternative: flash the firmware partition over U-Boot DFU

Use U-Boot Serial-Flash DFU when Linux does not boot, SSH is unavailable, or you
do not want to rely on the running Linux MTD path. The rebuilt LibreSDR
bootloader/env checks the board's active-low MIO12 DFU button during `preboot`.

Put the board in Serial-Flash DFU mode:

1. use a known-good SD or QSPI bootloader/env with the MIO12 DFU-button fix;
2. power-cycle while holding the LibreSDR DFU button;
3. release the button after Windows shows `VID_0456&PID_B674` / `USB download gadget`.

Then flash `output/libre.frm` from the host:

```powershell
.\tools\flash-libresdr-qspi-firmware-dfu.ps1 -Verify
```

The helper expects `dfu-util` on `PATH`, selects the `firmware.dfu` raw QSPI
alternate setting, writes only the `qspi-linux` area, and can upload a readback
for MD5 prefix verification with `-Verify`. On Windows, the DFU gadget may also
need a WinUSB/libusb-compatible driver binding before `dfu-util -l` can see it;
Device Manager showing `USB download gadget` is necessary but not always
sufficient.

## Optional: install the fixed QSPI bootloader/env

The physical DFU button and `maxcpus=2` fixes live in U-Boot/environment, not in
`output/libre.frm`. Flashing only `output/libre.frm` keeps the older QSPI
bootloader and environment already on the board.

After the rebuilt SD image has proven that the DFU button enters
`VID_0456&PID_B674`, generate QSPI-specific boot artifacts:

```powershell
.\tools\finalize-libresdr-qspi.ps1 -VivadoRoot C:\Xilinx
```

This creates:

```text
output/libresdr-qspi/BOOT-qspi.bin
output/libresdr-qspi/uboot-env.bin
```

`BOOT-qspi.bin` is FSBL + patched U-Boot only. It deliberately omits the
bitstream so it fits the existing 1 MiB `qspi-fsbl-uboot` partition. Do not flash
the SD-card `BOOT.bin` to QSPI; it contains FSBL + bitstream + U-Boot and is too
large for the current boot partition layout.

First make a backup without flashing:

```powershell
python flash_libresdr_qspi_boot.py --host 192.168.1.50
```

Then, if the backup succeeds and you are booted from the known-good SD image:

```powershell
python flash_libresdr_qspi_boot.py `
  --host 192.168.1.50 `
  --flash `
  --i-understand-this-writes-bootloader
```

This writes only:

```text
/dev/mtd0  qspi-fsbl-uboot
/dev/mtd1  qspi-uboot-env
```

It does not write `qspi-linux`; use `flash_libresdr_qspi.py` for
`output/libre.frm`. The tested post-reboot state is `maxcpus=2`, both Zynq CPUs
online, USB gadget configured, `iiod` running, and clean W25Q256 QSPI detection.

## Safety notes

- Do not power off during `flashcp`.
- The script refuses to flash without `--yes`.
- The script refuses to flash bootloader/env-looking MTD partitions.
- If `/etc/gps-timing-board` is missing, boot the staged SD image first. Only
  use `--force-board` if you have checked the target manually.
- Keep the upstream `baseclock_cpu750_ddr525` SD image or another known-good SD
  card available. Since the normal QSPI path does not overwrite U-Boot, recovery
  should still be possible through U-Boot/DFU or SD boot, but having a known-good
  card saves a lot of bench time.
- Read the recovery ladder before the first QSPI experiment:
  [`LIBRESDR_RECOVERY.md`](LIBRESDR_RECOVERY.md).

## What this does not do yet

This is not a full factory programmer for blank or corrupt QSPI. It does not
write the SD-card `BOOT.bin` into QSPI. The optional bootloader/env workflow
above writes a QSPI-specific `BOOT-qspi.bin` plus a generated environment image,
after backing up the current QSPI boot partitions.

The LibreSDR build now patches the generated U-Boot environment so the DFU
button check runs from `preboot` and uses the board's active-low
`PS_MIO12_500`/GPIO12 signal instead of Pluto's GPIO14 check. That change is
present in newly built `u-boot.elf`, SD `BOOT.bin`, QSPI `BOOT-qspi.bin`, and
staged `uEnv.txt`; flashing only `output/libre.frm` does not change an older
bootloader already installed in QSPI.
