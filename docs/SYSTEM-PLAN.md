# Passive-localization network — system plan

Planning doc for packaging several projects into one **passive RF localization network**: a set of
friend-owned edge nodes (GPS-timed SDRs + compute) that cooperatively locate emitters via TDOA/AoA,
coordinated through a cloud service over Tailscale.

> Status: planning. Lives in the `plutoplus-gps-timing` repo (the core) for now; **move into the new
> umbrella repo** once it exists. See [Networked TDOA](NETWORK.md) for the node-level architecture and
> [TDOA tooling](../tdoa/README.md) for the timing/sync constraints this all rests on.

## Components (independently-owned, different lifecycles)

| Component | Repo | Role in the system |
|---|---|---|
| **GPS timing firmware** (core) | this repo (`plutoplus-gps-timing`) | Per-node **time & frequency truth** — GPS/PPS stratum-1 clock, FPGA `pps_counter`, `xo_correction` sample-clock discipline. |
| **VITA-49 streamer** | https://github.com/lgarrido581/vita49-pluto-sdr | **Transport** — packetized IQ with timestamp/context metadata; the node→cloud / node→node IQ path. |
| **TDOA signal-processing lib** | (buddy's repo — TBD) | **Math** — cross-correlation, TDOA estimation, multilateration / AoA. |
| **Tailscale + edge runtime** | new (`infra/`, `node/`) | **Fabric + node agent** — tailnet, per-node capture→reduce→push. |
| **AWS coordinator** | new (`infra/aws/`) | **Cloud** — collects node reports, runs fusion. |

## Repo strategy: meta-repo with submodules (not a monorepo)

Because components have **different owners and release cadences**, use an umbrella **orchestration
repo** that references the others as **git submodules** and holds only the integration glue. Submodules
pin exact commits, so the system always builds against known-good component versions even while three
people push independently.

```
passive-loc/                     # umbrella repo (the "product")
├── README.md                    # system architecture — one source of truth
├── components/                  # submodules (each stays its own repo)
│   ├── gps-timing/              # → plutoplus-gps-timing
│   ├── vita49-streamer/         # → vita49-pluto-sdr
│   └── tdoa-lib/                # → buddy's lib
├── infra/
│   ├── tailscale/               # ACLs, tags, node naming (plutonode1, ...)
│   └── aws/                     # coordinator: IaC + collector service
├── node/                        # per-node edge runtime (runs on each Jetson)
│   └── ...                      # bringup + capture→reduce→push agent
├── experiments/                 # fm-calibration, two-node coherence, ...
└── docs/                        # NETWORK.md (system), DECISIONS.md (ADR log)
```

## Sequencing — validate the core before building the cloud

Prove the physics on the bench first; wrap infra around what works.

1. **FM cooperative calibration** *(do first — highest value, runnable on hardware today, zero cloud).*
   Capture a strong local FM station on the GPS-timed **Pluto+** (and an FMCOMMS5 channel),
   cross-correlate, measure the residual time/phase offset between captures. This is the roadmap's
   **T2/T3** validation made concrete and directly tests whether the `xo_correction` sample-clock lock
   holds. If this works, the timing core is real and worth scaling.
2. **Scaffold the umbrella repo** + add the three components as submodules.
3. **Node edge agent** — package `bringup.sh` + a `capture → edge-reduce → push(report)` runtime;
   VITA-49 streamer = transport, buddy's lib = the reduce/estimate step.
4. **AWS coordinator** — only now. Small instance (or object store) on the tailnet that collects
   reports and runs multilateration, behind a `push()` interface (VPS *or* S3 — decided in NETWORK.md).
5. **FMCOMMS5 GPS-discipline** *(parallel track)* — feed the Pluto+'s GPS-disciplined reference / PPS
   into the FMCOMMS5 so its 4 coherent channels are GPS-timestamped. The roadmap's Phase-1 freq-lock
   applied to the 4ch board. Does not block 1–4.

## First experiment in detail — FM cooperative calibration

- **Why FM:** strong, free, always-on, wideband enough for sharp cross-correlation; no TX license.
- **Setup:** node #1 has both SDRs on one wire (Pluto+ `ip:169.254.6.36`, FMCOMMS5 `ip:169.254.92.202`)
  fed from antenna(s). Tune ~96–104 MHz to a strong local station.
- **Measure:** capture GPS-second-aligned windows; cross-correlate Pluto+ vs FMCOMMS5 (and, later,
  node-vs-node). The correlation peak's sub-sample offset = residual inter-receiver time error; its
  drift over time = frequency-lock quality. Expect ~0 and *stable* once disciplined; drift without it.
- **Builds toward:** the same cross-correlation kernel becomes the node edge-reduce step; a known FM
  station also serves as a **shared reference** to null inter-node offset before correlating the target.

## Decisions carried in (see NETWORK.md)

- Compute split: **hybrid** — node GPU edge-reduce → cloud TDOA fusion.
- Cloud: **transport-agnostic** behind one `push()` — self-hosted VPS *or* managed object storage.
- Pluto+/SDRs stay **off** Tailscale; only the **Jetson** joins the tailnet (node `plutonode1`).
- Per-site GPS is the time source; **Tailscale is transport, not timing.**

## Open problems

- **FMCOMMS5 timestamping** — its sample clock is independent of the Pluto+'s GPS-disciplined clock;
  needs a shared reference or PPS marker (item 5). The hard gate for FMCOMMS5-based TDOA.
- **Trigger source** — how nodes agree which GPS-second to capture (cloud broadcast vs. rolling buffer).
- **Tailscale ACLs** — scope each friend's node to the coordinator only; tag nodes vs. coordinator.
- **Time-transfer validation across sites** — confirm independent GPS locks agree to the ns level
  needed for the target geometry (1 µs ≈ 300 m).
