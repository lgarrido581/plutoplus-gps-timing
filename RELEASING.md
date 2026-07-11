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
2. Build the artifact(s): Pluto+ `docker-run.sh --vivado <path> --hwlatch`; LibreSDR per
   `docs/LIBRESDR.md`. (Rootfs/script-only change? reuse the bitstream with `--prebuilt-bit` — the
   `fpga@1` sha must match the prior release.)
3. **Flash each board and run `smoke_test.py` → `SMOKE PASS`.** Paste the output into the release notes.
4. Tag `vX.Y.Z`, push the tag, create the release, attach each board's `.frm`.
5. Bitstream unchanged but rootfs fixed (like v2.0→v2.0.1)? Say so, and confirm `fpga@1` sha is
   identical to the superseded release — that is the proof the delta is only what you intended.

## Versioning
- New board / breaking change → bump **major** (v1→v2).
- Feature → **minor**. Fix (esp. a shipped-broken asset) → **patch**, and mark the superseded asset.
