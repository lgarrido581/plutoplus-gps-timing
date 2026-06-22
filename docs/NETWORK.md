# Networked TDOA (Phase 2 — remote nodes + cloud fusion)

Extends the single-site GPS-timed Pluto+ into a **multi-site passive-localization network**:
several friend-owned nodes, each a **Jetson Nano + Pluto+ + GPS/PPS + GPSDO**, reachable over
**Tailscale**, reporting to a shared **cloud coordinator** that runs the TDOA fusion.

This is transport/plumbing only. It does **not** replace the timing work — per-site GPS time
(coarse, done) and **GPSDO sample-clock frequency lock** (`tdoa/README.md` Phase 1, *still required*)
remain the gate for TDOA actually working. Tailscale is transport, **not** a time source: every site
derives common time from its own GPS, so WAN jitter never enters the time solution.

## Topology

```
 per site (×N, friend-owned):
   [GPS NMEA+PPS] ─► [Pluto+] ──USB / RNDIS, libiio──► [Jetson Nano] ──┐
   [GPSDO 40 MHz] ─► Pluto ext-ref      (GPS-disciplined,              │ Tailscale
                                          stratum-1 NTP, pps_counter)  │ (flat 100.x)
                                         edge capture + GPU reduce      │
                                                                        ▼
                                              [Cloud coordinator] ── collects reports,
                                              (VPS  -or-  object store)  runs multilateration
```

**Why the Nano is the only Tailscale node (Pluto is not):** the Pluto+ runs a stripped buildroot
rootfs on tiny, unprotected QSPI — adding a persistent Go daemon there is fragile and risks the
flash (see `RECOVERY.md`). The Pluto stays exactly what this repo already makes it (GPS time, NTP,
optional `pps_counter` FPGA latch); the **Nano** is the capture host, timestamper, and uplink, and
talks to the Pluto over `libiio` (USB or its RNDIS/Ethernet). One Nano + one Pluto = one node.

Tailscale gives every site flat `100.x` addressing with no port-forwarding / NAT traversal, so any
node reaches the coordinator and vice-versa regardless of each friend's home network.

## Decisions (this phase)

- **Compute split — HYBRID.** Nodes capture the same GPS-second window on a trigger, do a first-pass
  **edge reduction on the Jetson GPU** (decimate + cross-correlate against the reference, keep only
  IQ snippets / correlation peaks around detections), and ship the *reduced* payload (KB–low MB, not
  the 8 MB/s of full-rate IQ). The cloud does final **TDOA fusion / multilateration** across nodes.
  This keeps the WAN uplink bounded and survives bad home links, while leaving the cross-node
  alignment to a place that sees all nodes at once.
- **Cloud — transport-agnostic.** The node→cloud step targets either a **self-hosted VPS** on the
  tailnet *or* **managed object storage** (S3-style) with a serverless fusion job. Keep the node
  uploader behind a small interface (`push(report)`) so the same node code works against both; pick
  per-deployment.

## Build order

1. **Tailscale + node bring-up** ✅ scaffolded — `tdoa/node/bringup.sh`. Installs/links Tailscale on
   the Nano, verifies the Pluto over libiio, smoke-tests cloud reachability. Run it per site.
2. **Node↔cloud protocol** — `trigger → GPS-second capture → hybrid edge-reduce → push(report)`.
   Report = node id, GPS-second + sample index of detection(s), correlation peak(s) / reduced IQ,
   node clock-health (chrony tracking + `pps_counter` lock state). Coordinator stub behind `push()`.
3. **Cloud fusion** — collect ≥3 node reports for the same GPS-second, solve TDOA → multilateration.

## Bring-up

On each **Jetson Nano**:

```sh
# Install Tailscale (official) and join the tailnet:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up                    # open the printed URL to authenticate

# Then verify the node is fully wired (Tailscale up, Pluto reachable, cloud reachable):
CLOUD=100.x.y.z PLUTO=ip:pluto.local ./tdoa/node/bringup.sh
```

`bringup.sh` is the gate for a site being "on the network." It does not stream IQ — that is Phase 2
step 2.

## Open items / still-required

- **GPSDO frequency lock per node** (`tdoa/README.md` Phase 1) — the real TDOA gate; remote
  streaming does not substitute for it.
- **Trigger source** — how all nodes agree on *which* GPS-second to capture (cloud broadcast vs.
  always-on rolling buffer the coordinator queries). TBD in step 2.
- **Authn/ACLs** — Tailscale ACLs to scope each friend's node to the coordinator only.
