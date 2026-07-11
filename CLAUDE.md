# plutoplus-gps-timing — orientation for Claude

Standalone, public firmware project: turns a **Pluto+ (Zynq-7010)** — and, on a separate
target, a **LibreSDR Rev.5 (Zynq-7020)** — into a **GPS-disciplined timing + RF source**
(stratum-1 NTP, PPS-disciplined system clock, and on `--hwlatch` a GPS-disciplined AD936x
sample clock). Built in Docker on `sardylan/plutoplus` `fw-0.39`.

**This repo has no downstream dependencies.** It builds one artifact — `output/pluto.frm` —
and consumers just flash that. Keep it generic: nothing about any particular deployment or
downstream application belongs here.

## Building `pluto.frm`

`./docker-run.sh` builds everything in Docker and emits `output/pluto.frm`. Two cases:

- **Services / kernel / rootfs change only (no gateware):** plain `./docker-run.sh` — no Vivado
  needed. This is the common case (the timing daemons, capture services, `flash_frm.py`).
- **Any HDL / block-design change (new bitstream):** the `system_top.bit` must be synthesized in
  **Vivado 2022.2** (the ADI HDL is a `2022_r2` base; set `ADI_IGNORE_VERSION_CHECK=1` if your
  Vivado version trips the check). Two ways to get the bit:
  - `./docker-run.sh --vivado <path-to-Xilinx>` — mount a Linux Vivado install and synth
    in-container (full build), **or**
  - synth `system_top.bit` with your own local Vivado, then inject it:
    `./docker-run.sh --prebuilt-bit <system_top.bit> --hwlatch`.

  `--hwlatch` sets `PPS_HWLATCH=1` (hardware PPS latch on the F20 input). A pure services change
  does **not** need a new bitstream — reuse the last `system_top.bit` with `--prebuilt-bit`.

LibreSDR target: `--target libresdr`; its HDL is prepared with `tools/build-libresdr-hdl.ps1`
(native Windows Vivado) then passed via `--prebuilt-bit` — see the usage header in
`docker-run.sh`.

> The buildroot output is **not** byte-reproducible; independent rebuilds of the same source
> differ in md5 but carry the same behavior. Record the source commit + the resulting md5/sha256
> when you hand a `.frm` downstream.

## Flashing a radio

`python flash_frm.py output/pluto.frm --host <pluto-ip>` — SSH (`root`/`analog`, stock ADI
default) → on-board md5 verify → `flashcp` mtd3 → reboot. Only mtd3 is written; the FSBL/u-boot
and env partitions are untouched, so DFU recovery is always available. Prefer this repo's
`flash_frm.py` over any older vendored copy — it has the post-flash `dma.rx_ok` health check.

## Gotcha

The Pluto runs **busybox** — `killall`/`pgrep` are unreliable (easy to leave duplicate daemons).
Verify process state explicitly rather than trusting a kill.
