#!/usr/bin/env python3
"""Turn the sardylan fw-0.39 Pluto tree into a Fishball7020 / PlutoSky R1 tree.

Usage: apply_board.py <plutosdr-fw root> <vendor dir from fetch_vendor.sh>

- HDL: installs boards/fishball/hdl/* and the vendor's system_constr.xdc into
  hdl/projects/pluto (only when the content before the pps_counter marker
  differs, so an unchanged board does not force a re-synthesis).
- Device tree: installs the vendor zynq-pluto-sdr.dtsi / -revc.dts (Ethernet on
  MIO, LVDS AD9361, 1 GiB, SD card, 16 MiB QSPI) and patches them to match the
  factory devicetree.dtb: no clock hogs or button (the factory tree has neither),
  200 ppm refclk accuracy (it sets the xo_correction range), 2R2T. Adds the
  pps-gpio client, a PL UARTLite for GPS NMEA, and probes the transmitter at
  full attenuation (the board has a PA on each TX port).

Fails on a missing anchor rather than producing a half-patched tree.
"""
from pathlib import Path
import sys

ROOT = Path(sys.argv[1]).resolve()
VENDOR = Path(sys.argv[2]).resolve() / "fishwan"
BOARD = Path(__file__).resolve().parent

GPS_MARKERS = (
    "# ---- GPS timing counter (added by docker-build-inner.sh) ----",
    "# ---- pps_counter CDC (added by docker-build-inner.sh) ----",
)
# Linux gpio number of EMIO gpio_i[17] (EMIO starts after the 54 MIO lines).
PPS_GPIO = 54 + 17
XDC_HEADER = (
    "## Fishball7020 / PlutoSky R1 (XC7Z020 CLG400) pin constraints: the vendor's\n"
    "## system_constr.xdc (Fish-Wan @ 95aad369, boards/fishball/vendor.lock), as is.\n"
    "## The GPS PPS pin (V10, JP5 pin 7) is appended by docker-build-inner.sh.\n\n")


def base_of(text: str) -> str:
    for marker in GPS_MARKERS:
        i = text.find(marker)
        if i >= 0:
            text = text[:i]
    return text.rstrip("\n")


def install_text(new: str, dst: Path, name: str) -> bool:
    if dst.exists() and base_of(dst.read_text()) == base_of(new):
        return False
    dst.write_text(new)
    print(f"  {dst.relative_to(ROOT)} <- {name}")
    return True


def replace(text: str, old: str, new: str, path: str) -> str:
    if old not in text:
        raise SystemExit(f"apply_board: anchor missing in {path}: {old[:70]!r}")
    return text.replace(old, new, 1)


def cut(text: str, start: str, end: str, path: str) -> str:
    """Remove from `start` through the first `end` after it."""
    i = text.find(start)
    j = text.find(end, i)
    if i < 0 or j < 0:
        raise SystemExit(f"apply_board: block {start.strip()!r} not found in {path}")
    return text[:i] + text[j + len(end):]


def hdl() -> None:
    pdir = ROOT / "hdl/projects/pluto"
    if not pdir.is_dir():
        print("  hdl/projects/pluto absent (no Vivado) -- HDL step skipped")
        return
    changed = False
    for name in ("system_bd.tcl", "system_top.v", "system_project.tcl"):
        changed |= install_text((BOARD / "hdl" / name).read_text(), pdir / name, name)
    xdc = (VENDOR / "hdl/projects/pluto/system_constr.xdc").read_text().replace("\r\n", "\n")
    changed |= install_text(XDC_HEADER + xdc, pdir / "system_constr.xdc", "vendor system_constr.xdc")
    if changed:
        Path("/tmp/board_hdl_changed").write_text("1")


def devicetree() -> None:
    dts_dir = ROOT / "linux/arch/arm/boot/dts"
    src_dir = VENDOR / "linux/arch/arm/boot/dts"

    path = "zynq-pluto-sdr.dtsi"
    text = (src_dir / path).read_text()
    text = replace(text, "clock-accuracy = <500>; /* 200 ppm (ppb) */",
                   "clock-accuracy = <200000>; /* 200 ppm (ppb) */", path)
    (dts_dir / path).write_text(text)

    path = "zynq-pluto-sdr-revc.dts"
    text = (src_dir / path).read_text()
    text = cut(text, "&gpio0 {\n\tclock_extern_en {", "\n};\n", path)
    text = cut(text, "\tgpio_keys {", "\n\t};\n", path)
    text = cut(text, "\tone-bit-adc-dac@0 {", "\n\t};\n", path)
    text = replace(text, '\tmodel = "Analog Devices PlutoSDR Rev.C (Z7010/AD9363)";\n',
                   '\tmodel = "Analog Devices PlutoSDR Rev.C (Z7020/AD9361)";\n\n'
                   "\taliases {\n"
                   "\t\tmmc0 = &sdhci0;\n"
                   "\t\tserial1 = &gps_uart;\n"
                   "\t};\n", path)
    text = text.rstrip("\n") + (
        "\n\n&adc0_ad9364 {\n"
        "\t/* Probe with the transmitter muted: each TX port has a PA. */\n"
        "\tadi,tx-attenuation-mdB = <89750>;\n"
        "};\n"
        "\n"
        "&fpga_axi {\n"
        "\tgps_uart: serial@42c00000 {\n"
        "\t\tcompatible = \"xlnx,axi-uartlite-2.0\", \"xlnx,xps-uartlite-1.00.a\";\n"
        "\t\treg = <0x42c00000 0x1000>;\n"
        "\t\tinterrupt-parent = <&intc>;\n"
        "\t\tinterrupts = <0 58 4>;\n"
        "\t\tclock-frequency = <100000000>;\n"
        "\t\tcurrent-speed = <9600>;\n"
        "\t\tport-number = <0>;\n"
        "\t\tstatus = \"okay\";\n"
        "\t};\n"
        "};\n"
        "\n/ {\n"
        "\t/* GPS 1PPS on JP5 pin 7 (3V3_IO1, V10) -> EMIO gpio_i[17]. */\n"
        "\tpps {\n"
        '\t\tcompatible = "pps-gpio";\n'
        f"\t\tgpios = <&gpio0 {PPS_GPIO} 0>;\n"
        "\t};\n"
        "};\n")
    (dts_dir / path).write_text(text)
    print(f"  linux dts: vendor dtsi + {path} (GPS UART /dev/ttyUL0, pps-gpio on gpio {PPS_GPIO})")


hdl()
devicetree()
