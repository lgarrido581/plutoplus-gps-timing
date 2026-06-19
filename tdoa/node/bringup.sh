#!/bin/sh
# bringup.sh — Phase-2 edge-node bring-up. Runs ON THE JETSON NANO (Ubuntu/L4T).
#
# Verifies the three things a TDOA edge node needs before it can join the network:
#   1. Tailscale installed and the node is up on the tailnet (flat 100.x addressing).
#   2. The Pluto+ is reachable over libiio (USB or its RNDIS/Ethernet).
#   3. The cloud coordinator is reachable across the tailnet (transport smoke test).
#
# This does NOT capture or stream IQ yet — it just proves the fabric is wired so the
# node<->cloud protocol (next phase) has somewhere to run. See docs/NETWORK.md.
#
# Usage:
#   ./bringup.sh                         # auto-detect Pluto, skip cloud check
#   PLUTO=ip:192.168.2.1 CLOUD=100.x.y.z ./bringup.sh
#
# Env:
#   PLUTO   libiio URI for the Pluto    (default: ip:pluto.local, then ip:192.168.2.1)
#   CLOUD   tailnet IP/host of coordinator to ping (default: unset -> skipped)
set -eu

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  XX\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Tailscale ----------------------------------------------------------
say "Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  warn "tailscale not installed — installing (official script):"
  warn "    curl -fsSL https://tailscale.com/install.sh | sh"
  printf '    install now? [y/N] '
  read -r ans
  case "$ans" in
    y|Y) curl -fsSL https://tailscale.com/install.sh | sh ;;
    *)   die "install Tailscale, then re-run" ;;
  esac
fi
if ! tailscale status >/dev/null 2>&1; then
  warn "node is not up on the tailnet — bringing it up:"
  warn "    sudo tailscale up    (open the printed URL to authenticate)"
  sudo tailscale up
fi
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[ -n "$TS_IP" ] || die "no tailnet IPv4 — check 'sudo tailscale up'"
ok "tailnet IP: $TS_IP   (hostname: $(tailscale status --self --json 2>/dev/null | grep -o '\"DNSName\":\"[^\"]*' | head -n1 | cut -d'\"' -f4 || echo '?'))"

# --- 2. Pluto over libiio --------------------------------------------------
say "Pluto+ via libiio"
command -v iio_attr >/dev/null 2>&1 || warn "libiio tools not found — 'sudo apt install libiio-utils' (pyadi-iio also needs libiio)"

probe_pluto() {
  uri="$1"
  iio_attr -u "$uri" -C 2>/dev/null | grep -qi 'hw_model\|pluto\|ad936' && return 0
  return 1
}
PL="${PLUTO:-}"
if [ -z "$PL" ]; then
  for cand in ip:pluto.local ip:192.168.2.1 usb:; do
    if probe_pluto "$cand"; then PL="$cand"; break; fi
  done
fi
[ -n "$PL" ] || die "no Pluto found — set PLUTO=ip:<addr> or usb:<n> and re-run"
probe_pluto "$PL" || die "Pluto not reachable at '$PL'"
ok "Pluto reachable at: $PL"
# Surface GPS/timing health from the Pluto (it is our per-site time source).
if command -v ssh >/dev/null 2>&1; then
  host="$(printf '%s' "$PL" | sed 's/^ip://')"
  if [ "$PL" != "${PL#ip:}" ]; then
    say "Pluto GPS/PPS health (ssh root@$host)"
    ssh -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new "root@$host" \
      'chronyc tracking 2>/dev/null | grep -E "Reference ID|Leap|System time" || echo "chrony not answering"' \
      2>/dev/null || warn "ssh to Pluto failed (ok — not required for bring-up)"
  fi
fi

# --- 3. Cloud coordinator reachability -------------------------------------
say "Cloud coordinator"
if [ -n "${CLOUD:-}" ]; then
  if ping -c2 -W2 "$CLOUD" >/dev/null 2>&1; then
    ok "coordinator $CLOUD reachable over tailnet"
  else
    warn "cannot reach $CLOUD — is it joined to the same tailnet and up?"
  fi
else
  warn "CLOUD not set — skipping. Re-run with CLOUD=<tailnet ip/host> once the coordinator exists."
fi

say "bring-up complete"
echo "  node tailnet IP : ${TS_IP}"
echo "  pluto uri       : ${PL}"
echo "  cloud           : ${CLOUD:-<unset>}"
echo
echo "Next: node<->cloud protocol (trigger -> GPS-second capture -> hybrid edge-reduce -> upload)."
echo "See docs/NETWORK.md."
