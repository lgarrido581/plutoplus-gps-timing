# LibreSDR build and bring-up

The `libresdr` target ports the GPS timing stack to the LibreSDR Rev.5
(XC7Z020/AD936x). It does not replace the default Pluto+ target.

> This target is intentionally SD-card-only during bring-up. Do not install it
> in QSPI until the complete checklist below passes on your board.

## Wiring

All three signals are bank-35 3.3 V LVCMOS.

| GPS signal | LibreSDR signal | Zynq pin | FPGA direction |
|---|---|---|---|
| PPS | `EXT_GPIO0` | G15 | input |
| TX | `EXT_GPIO1` | K14 | UART RX input |
| RX (optional) | `EXT_GPIO2` | J14 | UART TX output |
| Ground | GND | — | — |

GPS TX crosses to the radio's RX. K14/J14 are reclaimed from the reference
design's expansion SPI interface; that SPI interface is unavailable in this
target. Use 3.3 V TTL UART, never RS-232 or 5 V logic.

## Windows prerequisites

- Docker Desktop using WSL2.
- Vivado 2022.2 installed natively, normally below `C:\Xilinx`.
- GNU Make for Windows. The Make bundled with Vitis HLS works; Cygwin `make`
  is also supported by ADI's HDL build.
- A FAT32-formatted SD card.

## Build

Run the Linux/Docker commands from WSL2 or Git Bash at the repository root.

### 1. Export the prepared HDL source

```sh
bash docker-run.sh --target libresdr --prepare-hdl
```

This pins and combines PlutoSDR v0.38, the LibreSDR port, and this repository's
GPS HDL overlay under `output/libresdr-hdl/`.

### 2. Build the FPGA image on Windows

```powershell
.\tools\build-libresdr-hdl.ps1 `
  -VivadoRoot C:\Xilinx `
  -MakeExe C:\Xilinx\Vitis_HLS\2022.2\tps\win64\msys64\mingw64\bin\make.exe
```

Alternatively, pass a Cygwin installation such as
`-MakeExe C:\cygwin64\bin\make.exe`.

The result is `output/libresdr-hdl/system_top.bit`.

### 3. Build Linux and stage the SD image

```sh
bash docker-run.sh --target libresdr \
  --prebuilt-bit output/libresdr-hdl/system_top.bit
```

### 4. Generate BOOT.bin with Windows bootgen

```powershell
.\tools\finalize-libresdr-sd.ps1 -VivadoRoot C:\Xilinx
```

Copy the **contents** of `output/libresdr-sd/` to the root of the FAT32 SD card.

## Expected devices and addresses

| Function | Interface |
|---|---|
| GPS UART | `/dev/ttyUL0`, 9600 8N1 |
| Linux PPS | `/dev/pps0`, EMIO GPIO 71 |
| AXI UART Lite | `0x40600000`, GIC SPI 54 (Linux IRQ 57 on the tested image) |
| AXI TDD (`CONFIG_ADI_AXI_TDD`) | `0x7C440000` |
| PPS counter | `0x7C460000` |
| Telemetry | ZMQ PUB 5560 / REP 5561 |
| Capture control | ZMQ REP 5562 |

## Hardware acceptance checklist

First boot with RF output terminated or otherwise safely configured.

```sh
cat /etc/gps-timing-board
ls -l /dev/ttyUL0 /dev/pps0
stty -F /dev/ttyUL0 9600 raw -echo
# gpsd normally owns ttyUL0; use gpsmon, or stop gpsd before a raw `cat`.
gpsmon
ppstest /dev/pps0

chronyc sources -v
chronyc tracking

devmem 0x7C460000 32
devmem 0x7C460008 32
devmem 0x7C440000 32

iio_info
iio_readdev -b 8192 cf-ad9361-lpc voltage0 voltage1 > /tmp/rx.iq
pluto_zmqd --print
```

Then run `hdl/pps_counter/tdd_verify.sh` and
`hdl/pps_counter/tdd_tx_test.sh`. Verify PPS loss enters holdover, PPS return
reacquires, non-TDD streaming still works, and the ZMQ capture endpoint returns
a timestamped SigMF capture.

The target is not considered hardware validated until a cold SD boot passes
Ethernet, both RX channels, TX, GPS/chrony, sample-clock discipline, TDD capture,
and both ZMQ services.

## Recovery

Remove the SD card and boot the previously known-good LibreSDR card. The workflow
above never writes QSPI. Retain a copy of the upstream
`baseclock_cpu750_ddr525` SD image before testing.
