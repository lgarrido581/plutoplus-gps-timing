#!/bin/sh
# Publish a firmware Release carrying BOTH radio variants + a SHA256SUMS manifest.
#
#   ./release_firmware.sh v1.10                          # uses output/pluto.frm + output/libre.frm
#   ./release_firmware.sh v1.10 build/pluto.frm build/libre.frm
#
# Downstream projects pin a firmware release by tag and each node fetches the asset
# for its OWN board (pluto.frm for Pluto+, libre.frm for LibreSDR). Consumers read the
# per-file hashes from the SHA256SUMS asset (no need to download the 16 MB .frm just to
# learn its hash). Publish whichever variants you built — at least one is required.
#
# Requires: gh (authenticated) + sha256sum (or shasum). POSIX sh (no bashisms) so it
# passes the repo's `sh -n` / shellcheck CI gate.
set -eu

TAG="${1:-}"; [ -n "$TAG" ] || { echo "usage: $0 <tag> [pluto.frm] [libre.frm]" >&2; exit 1; }
PLUTO="${2:-output/pluto.frm}"
LIBRE="${3:-output/libre.frm}"
REPO="${GPS_REPO:-lgarrido581/plutoplus-gps-timing}"

command -v gh >/dev/null || { echo "error: gh (GitHub CLI) is required." >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SUMS="$WORK/SHA256SUMS"; : > "$SUMS"

stage() {  # <src-path> <release-asset-name>: copy into $WORK + hash; return 0 iff staged
  [ -f "$1" ] || { echo "    skip $2 (no $1)"; return 1; }
  cp "$1" "$WORK/$2"
  ( cd "$WORK" && sha "$2" >> SHA256SUMS )
  echo "    + $2"
}

# POSIX sh has no arrays; accumulate the staged asset paths in the positional params.
echo "==> staging firmware variants for ${TAG}"
set --
stage "$PLUTO" pluto.frm && set -- "$@" "$WORK/pluto.frm"
stage "$LIBRE" libre.frm && set -- "$@" "$WORK/libre.frm"
[ "$#" -gt 0 ] || { echo "error: no .frm found (looked at $PLUTO, $LIBRE)" >&2; exit 1; }
set -- "$@" "$SUMS"

echo "==> publishing ${REPO} release ${TAG}"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" --repo "$REPO" --clobber "$@"
else
  gh release create "$TAG" --repo "$REPO" --title "$TAG" \
     --notes "GPS-timing firmware ${TAG}. Per-radio variants: pluto.frm (Pluto+/Zynq-7010), libre.frm (LibreSDR/Zynq-7020). See SHA256SUMS." \
     "$@"
fi

names=""
for a in "$@"; do names="$names ${a##*/}"; done
echo "==> done: ${TAG} on ${REPO} (${names# })"
