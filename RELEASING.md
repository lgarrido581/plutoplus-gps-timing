# Releasing — the gate that stops broken updates

We ship firmware for **multiple boards** (Pluto+, LibreSDR) and cut **tagged releases**. v2.0 shipped a
capture regression that compiled clean, passed static analysis, and only failed **at runtime, on one
board** — because nothing ran an actual capture before the tag. This gate makes that impossible to
repeat: **no tag/release until the hardware-free CI passes AND `smoke_test.py` passes on _every_
supported board.**

## Two layers

**1. CI (hardware-free) — runs on every PR** (`.github/workflows/ci.yml` → `test/run_ci.sh`):
- `sh -n` + shellcheck on all scripts
- **`test/check_iio_return.sh`** — the libiio return-value contract that broke v2.0
- `gcc -Wall -Wextra -Werror` + `cppcheck` on `services/*.c`
- `py_compile`, `test_xo_correct.sh`, `test_tdd_window_model.py`
- (Vivado `xvlog`/OOC-synth runs in the `--vivado` build.)

CI catches the *class* (return-contract, lint, build). It **cannot** catch a runtime, board-specific
regression — that is what the smoke test is for.

**2. Per-board hardware smoke test — the release gate** (`tools/smoke_test.py`):
Flash the candidate firmware to a real board, then run it. It asserts timing is live **and an actual
GPS-anchored capture succeeds** (the check that would have caught v2.0):
```sh
pip install paramiko pyzmq
python tools/smoke_test.py --host <board-ip> --board plutoplus   # expect: SMOKE PASS
python tools/smoke_test.py --host <board-ip> --board libresdr    # run on EVERY board
```
The bug was Pluto-only; testing one board would still have shipped it — so **run it on each board you
ship in the release.**

## Release checklist

1. `git` tree clean; CI green on the release commit.
2. Build the artifact(s) with the **full** build: Pluto+ `docker-run.sh --vivado <path> --hwlatch`;
   LibreSDR per `docs/LIBRESDR.md`. **Do NOT release a `--prebuilt-bit` build.** v2.0.1 shipped broken
   from exactly that shortcut: the injected bitstream was a **truncated 241 KB extract of the real 964 KB
   bit** (the `fdt` pip lib silently truncates large `data` props), so the PL couldn't configure → brick.
   `--prebuilt-bit` is a **dev-iteration** convenience only; a tagged artifact is always a full `--vivado`
   build that synthesizes the real bitstream.
3. **Verify the built artifact:** `sh test/check_frm_images.sh output/pluto.frm [prev-release.frm]` — it
   uses the non-truncating `mkimage -l` (never the `fdt` lib) to assert `fpga@1`/kernel/ramdisk are
   full-size (catches the v1.5 and v2.0.1 truncated-bitstream bricks) and that the `.frm` md5 trailer is
   valid. This is a hard gate: a shrunk image is a STOP.
4. **Flash each board with `update_frm.sh` / `flash_frm.py`, then run `smoke_test.py` → `SMOKE PASS`.**
   - The flash MUST set `fit_size` (U-Boot reads exactly `fit_size` bytes of the FIT at boot; a stale
     value = truncated FIT = brick). `flash_frm.py` delegates to the board's `update_frm.sh` and asserts
     `fit_size` matches the new image — never hand-roll a `flashcp`. See `FLASHING.md`.
   - After flashing, sanity-check on the board: `fw_printenv fit_size` == the new FIT.itb size (`.frm`
     bytes − 33, as `printf %X`), and the mtd3 FIT header `totalsize` matches it.
   - Paste the `smoke_test.py` output into the release notes.
5. Tag `vX.Y.Z`, push the tag, create the release, attach each board's `.frm`.
6. Bitstream unchanged but rootfs fixed (like v2.0→v2.0.1)? Say so. The `fpga@1` sha need not be
   bit-identical across a fresh `--vivado` synth (it re-synthesizes), but it must be the **same HDL** —
   note the `hdl/` commit. The proof the delta is only what you intended is the diff of the release
   commits plus `SMOKE PASS` on the new artifact, not a byte-identical bitstream.

## Versioning
- New board / breaking change → bump **major** (v1→v2).
- Feature → **minor**. Fix (esp. a shipped-broken asset) → **patch**, and mark the superseded asset.
