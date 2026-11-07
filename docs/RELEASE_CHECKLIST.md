# Firmware release checklist

This repo has firmware for two boards; a release carries the variant for each board that was
built and smoke-tested for it, so a consumer can pick the one that matches its hardware:

- **`pluto.frm`** — Pluto+ / Zynq-7010
- **`libre.frm`** — LibreSDR / Zynq-7020

Which boards a release carries is stated in [`CHANGELOG.md`](../CHANGELOG.md). v2.1.0 and v2.2.0
are Pluto+-only; LibreSDR stays on v2.0.4 until it is smoke-tested on that board.

Two release types:

- **beta** — ONE rolling pre-release (git tag `beta`, marked *prerelease*). Assets are
  overwritten on every publish, so there is exactly one `beta` object and it never shows up as
  "Latest". Use it for validation builds.
- **stable** — a full semver Release (`vX.Y.Z`, `--latest`). This is the official history.

Every release MUST carry a `SHA256SUMS` asset plus the `.frm` of each board it covers, so a
consumer can verify integrity and select by board. Say in the CHANGELOG which boards that is.

---

## Preconditions (both beta and stable)

- [ ] Source committed; working tree clean (`git status`).
- [ ] The **firmware version is embedded** in the build for each variant so it is reported at
      runtime, and the version-consistency CI check passes on the PR (see `.github/workflows/`).
- [ ] Bump the version consistently across the build inputs (single source of truth) so both
      variants report the intended version.

---

## Build each variant the release carries

- [ ] **Pluto+ (`pluto.frm`):**
      `bash docker-run.sh` → `output/pluto.frm`. This reuses the pinned `output/working.bit`
      (= `--prebuilt-bit output/working.bit --hwlatch`) and fails unless `fpga@1` matches the
      sha256 in `boards/plutoplus/fpga.sha256pin`. Do **not** extract a bit from a prior `.frm`
      instead — a truncated extract is how v2.0.1 bricked (see `docs/BUILD.md`). For a gateware
      change, build with `--vivado <path> --hwlatch` and update `output/working.bit` + the pin.
- [ ] **LibreSDR (`libre.frm`)** — only if the release carries LibreSDR:
      `bash docker-run.sh --target libresdr [--prebuilt-bit output/libresdr-hdl/system_top.bit]`
      → `output/libre.frm`.
      NOTE: the LibreSDR target needs the `LICENSE.html` generation on-branch — `SKIP_LEGAL=1`
      makes genimage abort at target-finalize ("could not setup LICENSE.html"). Build the HDL
      first with `tools/build-libresdr-hdl.ps1` if the prebuilt bit is stale.

---

## Verify each `.frm` (before flashing anything)

- [ ] Run `check_frm_images` on each artifact — it must PASS (not falsely quarantine).
- [ ] Record the FIT sub-image hashes (fpga / ramdisk / kernel) and confirm the intended parts
      changed and the others didn't (e.g. a services-only build changes ramdisk, not the FPGA).
- [ ] Record `md5sum` + size of each `.frm`.

---

## Validate on hardware (one of each board the release carries)

- [ ] Back up the current QSPI (`mtd`) partition first, for rollback.
- [ ] Flash a Pluto+ with `flash_frm.py <pluto.frm> [--host <ip>]` (on-board md5 check →
      the board's `update_frm.sh`, which writes mtd3 and sets `fit_size` → `fit_size` check →
      reboot). Flash a LibreSDR with `flash_libresdr_qspi.py <libre.frm>` (bare `flashcp` to mtd3;
      see the `fit_size` caution in `FLASHING.md`).
- [ ] After reboot, confirm on each board: GPS acquires a fix, 1PPS is present and disciplined
      (advancing), the RX path is alive, and the sample rate matches the board (Pluto+ vs
      LibreSDR clock the AD9361 data path differently).
- [ ] Confirm the runtime telemetry reports the **embedded firmware version** for each variant.
- [ ] Note: after a flash, a brief settling period is normal while the XO discipline loop
      converges; a solid-LED / no-USB state right after a flash is usually the GPS NMEA stream
      interrupting u-boot autoboot — disconnect GPS + power-cycle, don't assume a brick.

---

## Publish

- [ ] For a Pluto+-only release, **delete (or rebuild) any stale `output/libre.frm`** before
      running `release_firmware.sh`: it attaches `output/libre.frm` whenever the file exists.
- [ ] Compute `SHA256SUMS` covering the `.frm` files the release carries.
- [ ] **beta:** create-once the `beta` pre-release, then
      `gh release upload beta --clobber <the .frm files> SHA256SUMS` and retarget the tag.
- [ ] **stable:** `gh release create vX.Y.Z --latest` with the `.frm` files and `SHA256SUMS`.
- [ ] Verify the release lists the variants it carries + `SHA256SUMS`, and (for stable) that
      `GET /releases/latest` resolves to it and NOT the `beta` pre-release.
- [ ] Release notes: version, which sub-images changed (fpga/ramdisk/kernel), per-board md5.

## Rollback

- [ ] Keep the previous release. To roll a board back, re-flash the prior `.frm` (or restore the
      `mtd` backup taken above) with the same flash tool.
