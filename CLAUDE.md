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
implicitly synthesizes or downloads a bitstream — a bare run reuses the pinned known-good bit,
so you cannot accidentally ship the wrong gateware. That bit, `output/working.bit`, is a **local
file, not in git** (`.gitignore` excludes `output/` and `*.bit`); a fresh clone must obtain it
first or the build refuses to run — see `docs/BUILD.md`. Two cases:

- **Services / kernel / rootfs change only (no gateware change):** plain `./docker-run.sh` — no
  Vivado needed. It auto-reuses `output/working.bit` (the coincident-capture / hardware-PPS-latch
  bitstream) **and** builds the matching `PPS_HWLATCH=1` services (`S70xocorrect` sample-clock
  discipline). This is the common case (timing daemons, capture services, `flash_frm.py`, the login
  banner). It is exactly equivalent to `./docker-run.sh --prebuilt-bit output/working.bit --hwlatch`.
- **Any HDL / block-design change (new bitstream):** the `system_top.bit` must be re-synthesized —
  **Vivado 2023.2** for the in-container build (what `docker-build-inner.sh` expects); a local synth
  you inject may use another compatible version (set `ADI_IGNORE_VERSION_CHECK=1` if it trips the
  check):
  - `./docker-run.sh --vivado <path-to-Xilinx> --hwlatch` — synth in-container (full build), **or**
  - synth `system_top.bit` locally, then inject it:
    `./docker-run.sh --prebuilt-bit <system_top.bit> --hwlatch` (a reuse build, so the pin gate
    fails it until the pin holds the new bit's sha256).

  After validating a *new* bit on hardware, refresh `output/working.bit` **and** the pinned hash in
  `boards/plutoplus/fpga.sha256pin` in the same commit. `--hwlatch` sets `PPS_HWLATCH=1` (F20
  hardware PPS latch + the `S70xocorrect` sample-clock service).

> **Guardrail — why a bare `./docker-run.sh` is safe now.** The old default silently pulled a
> *stock* bit with **no `pps_counter`**; the radio then boots `pps=N` / GPS-untrusted even though
> chrony is PPS-locked, and nothing tells you why. Now the script refuses to build without a
> bitstream source (defaulting to `output/working.bit`), every build prints `fpga@1 sha256`, and on
> the bitstream-reuse path (`--prebuilt-bit`, including the bare default) `check_frm_images.sh`
> **fails the build** if that hash ≠ `boards/plutoplus/fpga.sha256pin`. A `--vivado` build is not
> checked against the pin.
> `output/working.bit` = the coincident-capture bit, sha256 `4c80a8c4…d87d0f`.

LibreSDR target: `--target libresdr`; its HDL is prepared with `tools/build-libresdr-hdl.ps1`
(native Windows Vivado) then passed via `--prebuilt-bit` — see the usage header in
`docker-run.sh`.

> The buildroot output is **not** byte-reproducible; independent rebuilds of the same source
> differ in md5 but carry the same behavior. Record the source commit + the resulting md5/sha256
> when you hand a `.frm` downstream.

## Publishing a firmware release

Downstream projects pin a firmware release by tag and each node fetches the asset for
its **own** board. A release carries the `.frm` of each board it covers plus a `SHA256SUMS`
so consumers can learn per-file hashes without downloading the 16 MB `.frm`. Which boards
a release covers is stated in `CHANGELOG.md` (v2.1.0 and v2.2.0 are Pluto+-only). The normal
release build reuses the pinned bitstream (bare `./docker-run.sh`); see `RELEASING.md`.

```sh
./release_firmware.sh "v$(cat VERSION)"           # output/pluto.frm + output/libre.frm, if present
./release_firmware.sh "v$(cat VERSION)" build/pluto.frm build/libre.frm
```

The tag must equal `v` + the `VERSION` file or the script exits. Assets on the tag: `pluto.frm`
(Pluto+/Zynq-7010), `libre.frm` (LibreSDR/Zynq-7020), `SHA256SUMS`. The script attaches every
variant file it finds (at least one required) — **delete or rebuild a stale `output/libre.frm`**
before a Pluto+-only release. Re-running `--clobber`s the assets so a tag can be topped up when
the second variant is ready.

## Flashing a radio

`python flash_frm.py output/pluto.frm --host <pluto-ip>` — SSH (`root`/`analog`, stock ADI
default) → on-board md5 verify → the board's `/sbin/update_frm.sh` (writes mtd3 and sets
`fit_size`) → `fit_size` check → reboot. Only mtd3 is written; the FSBL/u-boot and env partitions
are untouched, so DFU recovery is always available. Prefer this repo's `flash_frm.py` over any older
vendored copy — after reboot it prints PPS state and `dma.rx_ok` (printed for you to read, not
asserted).

## Gotcha

The Pluto runs **busybox** — `killall`/`pgrep` are unreliable (easy to leave duplicate daemons).
Verify process state explicitly rather than trusting a kill.
