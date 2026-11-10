#!/bin/bash
# Fetch the pinned Fishball7020 vendor inputs listed in vendor.lock into
# <dest>/<repo>/<path>. Verifies every sha256; re-uses files already present with
# the right hash (the dest is the build's source cache).
# Usage: fetch_vendor.sh <dest-dir>
set -euo pipefail

LOCK="$(dirname "$0")/vendor.lock"
DEST="$1"

grep -E '^[0-9a-f]{64}  ' "$LOCK" | while read -r sum ref; do
    key="${ref%%:*}"; path="${ref#*:}"
    read -r slug commit < <(awk -v k="$key" '$1 == "repo" && $2 == k {print $3, $4}' "$LOCK")
    [ -n "${commit:-}" ] || { echo "vendor.lock: no repo line for '$key'" >&2; exit 1; }
    out="$DEST/$key/$path"
    if [ -f "$out" ] && echo "$sum  $out" | sha256sum -c --status; then
        continue
    fi
    mkdir -p "$(dirname "$out")"
    curl -sSfL -o "$out.part" "https://raw.githubusercontent.com/$slug/$commit/${path// /%20}"
    if ! echo "$sum  $out.part" | sha256sum -c --status; then
        echo "vendor.lock: sha256 mismatch for '$ref' at $commit" >&2
        rm -f "$out.part"
        exit 1
    fi
    mv "$out.part" "$out"
    echo "  fetched $ref"
done
