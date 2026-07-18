# Firmware release checklist

This repo ships firmware for two boards, released together so a consumer can pick the variant
that matches its hardware:

- **`pluto.frm`** — Pluto+ / Zynq-7010
- **`libre.frm`** — LibreSDR / Zynq-7020

Two release types:

- **beta** — ONE rolling pre-release (git tag `beta`, marked *prerelease*). Assets are
  overwritten on every publish, so there is exactly one `beta` object and it never shows up as
  "Latest". Use it for validation builds.
- **stable** — a full semver Release (`vX.Y.Z`, `--latest`). This is the official history.

Every release MUST carry **both** `.frm` variants plus a `SHA256SUMS` asset, so a consumer can
verify integrity and select by board.

---

## Preconditions (both beta and stable)

- [ ] Source committed; working tree clean (`git status`).
- [ ] The **firmware version is embedded** in the build for each variant so it is reported at
      runtime, and the version-consistency CI check passes on the PR (see `.github/workflows/`).
- [ ] Bump the version consistently across the build inputs (single source of truth) so both
      variants report the intended version.

---

## Build both variants

- [ ] **Pluto+ (`pluto.frm`):**
      `bash docker-run.sh [--prebuilt-bit output/working.bit] [--hwlatch]` → `output/pluto.frm`.
      For a services-only change, extract the known-good FPGA bit from the prior `.frm` and pass
      `--prebuilt-bit` instead of re-synthesizing.
- [ ] **LibreSDR (`libre.frm`):**
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

## Validate on hardware (one of each board)

- [ ] Back up the current QSPI (`mtd`) partition first, for rollback.
- [ ] Flash a Pluto+ with `flash_frm.py <pluto.frm> [--host <ip>]` (md5-verify → flashcp →
      reboot). Flash a LibreSDR with `flash_libresdr_qspi.py <libre.frm>` (mtd3 path).
- [ ] After reboot, confirm on each board: GPS acquires a fix, 1PPS is present and disciplined
      (advancing), the RX path is alive, and the sample rate matches the board (Pluto+ vs
      LibreSDR clock the AD9361 data path differently).
- [ ] Confirm the runtime telemetry reports the **embedded firmware version** for each variant.
- [ ] Note: after a flash, a brief settling period is normal while the XO discipline loop
      converges; a solid-LED / no-USB state right after a flash is usually the GPS NMEA stream
      interrupting u-boot autoboot — disconnect GPS + power-cycle, don't assume a brick.

---

## Publish

- [ ] Compute `SHA256SUMS` covering `pluto.frm` and `libre.frm`.
- [ ] **beta:** create-once the `beta` pre-release, then
      `gh release upload beta --clobber pluto.frm libre.frm SHA256SUMS` and retarget the tag.
- [ ] **stable:** `gh release create vX.Y.Z --latest` with `pluto.frm`, `libre.frm`, `SHA256SUMS`.
- [ ] Verify the release lists **both** variants + `SHA256SUMS`, and (for stable) that
      `GET /releases/latest` resolves to it and NOT the `beta` pre-release.
- [ ] Release notes: version, which sub-images changed (fpga/ramdisk/kernel), per-board md5.

## Rollback

- [ ] Keep the previous release. To roll a board back, re-flash the prior `.frm` (or restore the
      `mtd` backup taken above) with the same flash tool.
