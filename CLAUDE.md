# plutoplus-gps-timing — orientation for Claude

Standalone, public firmware project: turns a **Pluto+ (Zynq-7010)** — and, on a separate
target, a **LibreSDR Rev.5 (Zynq-7020)** — into a **GPS-disciplined timing + RF source**
(stratum-1 NTP, PPS-disciplined system clock, and on `--hwlatch` a GPS-disciplined AD936x
sample clock). Built in Docker on `sardylan/plutoplus` `fw-0.39`.

**This repo has no downstream dependencies.** It builds one artifact — `output/pluto.frm` —
and consumers just flash that. Keep it generic: nothing about any particular deployment or
downstream application belongs here.

## Building `pluto.frm`

`./docker-run.sh` builds everything in Docker and emits `output/pluto.frm`. It **never**
implicitly synthesizes or downloads a bitstream — a bare run reuses the committed known-good bit,
so you cannot accidentally ship the wrong gateware. Two cases:

- **Services / kernel / rootfs change only (no gateware change):** plain `./docker-run.sh` — no
  Vivado needed. It auto-reuses `output/working.bit` (the coincident-capture / hardware-PPS-latch
  bitstream) **and** builds the matching `PPS_HWLATCH=1` services (`S70xocorrect` sample-clock
  discipline). This is the common case (timing daemons, capture services, `flash_frm.py`, the login
  banner). It is exactly equivalent to `./docker-run.sh --prebuilt-bit output/working.bit --hwlatch`.
- **Any HDL / block-design change (new bitstream):** the `system_top.bit` must be synthesized in
  **Vivado 2022.2** (the ADI HDL is a `2022_r2` base; set `ADI_IGNORE_VERSION_CHECK=1` if your
  Vivado version trips the check):
  - `./docker-run.sh --vivado <path-to-Xilinx> --hwlatch` — synth in-container (full build), **or**
  - synth `system_top.bit` locally, then inject it:
    `./docker-run.sh --prebuilt-bit <system_top.bit> --hwlatch`.

  After validating a *new* bit on hardware, refresh `output/working.bit` **and** the pinned hash in
  `boards/plutoplus/fpga.sha256pin` in the same commit. `--hwlatch` sets `PPS_HWLATCH=1` (F20
  hardware PPS latch + the `S70xocorrect` sample-clock service).

> **Guardrail — why a bare `./docker-run.sh` is safe now.** The old default silently pulled a
> *stock* bit with **no `pps_counter`**; the radio then boots `pps=N` / GPS-untrusted even though
> chrony is PPS-locked, and nothing tells you why. Now the script refuses to build without a
> bitstream source (defaulting to `output/working.bit`), every build prints `fpga@1 sha256`, and
> `check_frm_images.sh` **fails the build** if that hash ≠ `boards/plutoplus/fpga.sha256pin`.
> `output/working.bit` = the coincident-capture bit, sha256 `4c80a8c4…d87d0f`.

LibreSDR target: `--target libresdr`; its HDL is prepared with `tools/build-libresdr-hdl.ps1`
(native Windows Vivado) then passed via `--prebuilt-bit` — see the usage header in
`docker-run.sh`.

> The buildroot output is **not** byte-reproducible; independent rebuilds of the same source
> differ in md5 but carry the same behavior. Record the source commit + the resulting md5/sha256
> when you hand a `.frm` downstream.

## Publishing a firmware release (both radio variants)

Downstream projects pin a firmware release by tag and each node fetches the asset for
its **own** board. A release must therefore carry **both** variants plus a `SHA256SUMS`
so consumers can learn per-file hashes without downloading the 16 MB `.frm`:

```sh
./release_firmware.sh v1.10                       # output/pluto.frm + output/libre.frm
./release_firmware.sh v1.10 build/pluto.frm build/libre.frm
```

Assets on the tag: `pluto.frm` (Pluto+/Zynq-7010), `libre.frm` (LibreSDR/Zynq-7020),
`SHA256SUMS`. Publish whichever variants you built (at least one required); re-running
`--clobber`s the assets so a tag can be topped up when the second variant is ready.

## Flashing a radio

`python flash_frm.py output/pluto.frm --host <pluto-ip>` — SSH (`root`/`analog`, stock ADI
default) → on-board md5 verify → `flashcp` mtd3 → reboot. Only mtd3 is written; the FSBL/u-boot
and env partitions are untouched, so DFU recovery is always available. Prefer this repo's
`flash_frm.py` over any older vendored copy — it has the post-flash `dma.rx_ok` health check.

## Gotcha

The Pluto runs **busybox** — `killall`/`pgrep` are unreliable (easy to leave duplicate daemons).
Verify process state explicitly rather than trusting a kill.
