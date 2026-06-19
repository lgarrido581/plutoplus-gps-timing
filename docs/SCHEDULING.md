# GPS-scheduled TX/RX — PPS-synced TDD + compare-trigger

Design note for deterministic, GPS-aligned capture and waveform playback,
coordinated across nodes. Builds on the `pps_counter` (v1.3) and the Pluto's
existing `axi_tdd` core. ADI TDD reference:
<https://analogdevicesinc.github.io/hdl/library/axi_tdd/index.html>.

## The Pluto already gates the DMAs with TDD

From the stock `system_bd.tcl`:
```tcl
ad_connect axi_tdd_0/tdd_channel_1  axi_ad9361_adc_dma/sync   # gates RX capture start
ad_connect axi_tdd_0/tdd_channel_2  axi_ad9361_dac_dma/sync   # gates TX playback start
ad_connect axi_tdd_0/sync_in        tdd_ext_sync              # external frame sync (dangling today)
ad_connect axi_ad9361/l_clk         axi_tdd_0/clk             # sample-clock domain
```
Built with `TDD_SYNC_EXT=1` + `TDD_SYNC_EXT_CDC=1` — the frame can start on an
external sync edge. The only missing piece is a **GPS reference** for that edge.

## Path A — PPS-synced TDD (reuse, low effort, driver-supported)

One BD wire: feed the F20 PPS (already in the PL for the hardware latch) into the
TDD sync:
```tcl
ad_connect pps_ext  axi_tdd_0/sync_in     # GPS PPS re-arms the frame every second
```
- Set the TDD frame length to the sample rate (≈ 30.72e6) so it **re-locks each
  PPS** (no drift accumulation).
- Configure per-channel on/off windows via the ADI TDD Linux/IIO driver.
- Result: **RX capture and DAC waveform playback start at GPS-aligned offsets**,
  repeating, identical across every node. Best for framed/periodic schedules
  (TDMA slots, duty-cycled RX, repeating beacon bursts).

## Path B — compare-trigger in `pps_counter` (new HDL, absolute one-shots)

For "fire once at absolute GPS time T," add a compare to the existing IP:

| offset | reg | bits |
|---|---|---|
| 0x1C | `TARGET`    | RW — sample count to fire at (GPS-anchored) |
| 0x20 | `TRIG_CTRL` | RW — bit0 `arm`, bit1 `mode` (0=one-shot, 1=periodic) |
| 0x24 | `TRIG_STAT` | RO — bit0 `fired` |

Logic (cnt_clk domain): when `arm && counter == TARGET`, emit a 1-sample trigger
pulse → route to `axi_ad9361_dac_dma/sync` (TX start), `axi_tdd_0/sync_in`, or a
pin; set `fired`; auto-disarm in one-shot mode.

Userspace:
```sh
# transmit/playback at GPS time = now + offset_s
TARGET = PPS_COUNT + round(offset_s * PPS_DELTA)   # PPS_DELTA = measured samples/sec
devmem TARGET ; devmem TRIG_CTRL = arm
```
Note: the 32-bit counter wraps ~140 s @ 30.72 MHz, so schedule relative to the
latest `PPS_COUNT` (sub-second/second offsets). Widen the counter for longer
horizons.

Most systems want **both**: TDD for the repeating frame, the compare-trigger for
absolute one-shot events (e.g. two-way ranging, "TX at 12:00:00.000 GPS").

## Precision & limits

- **Resolution:** ±1 sample (~33 ns) + GPS PPS inter-receiver error (~tens of ns
  consumer GPS, less with NEO-M8T). Node-to-node event alignment lands in the
  **tens-of-ns** range — excellent for time-multiplexed coordination.
- **It aligns timing/envelope, not carrier phase** → this gives *coordinated*,
  not *coherent*, transmission. See **[Coherent beamforming](#coherent-beamforming-what-it-would-take)**.

## Coherent beamforming — what it would take

GPS scheduling aligns nodes to ~tens of ns. Coherent (phase-aligned) distributed
TX needs carrier-phase alignment to a fraction of a wavelength — at 1 GHz, λ/20 ≈
**50 ps** — roughly **1000× tighter** than GPS timing provides. GPS alone cannot
do it. The two regimes:

- **Coherent distributed *reception*** — *achievable* as an evolution of this
  system: capture GPS-timestamped IQ at each node (already have it), then estimate
  and correct residual inter-node carrier phase **in post-processing** at the
  fusion center (pilot/reference-aided or blind). Frequency lock (`xo_correction`)
  + good timestamps + calibration get you there.
- **Coherent distributed *transmission* (beamforming)** — *research-grade.* Phase
  alignment must happen in real time before transmit, requiring **all** of:
  1. a **phase-coherent reference** — either a shared/distributed LO or a
     White-Rabbit-class (sub-ns/ps) link over fiber, **or** a real-time
     **closed-loop phase-calibration** protocol (target/receiver feedback, or
     inter-node two-way phase exchange);
  2. **low phase noise** over the coherence interval — OCXO/Rb class, not the
     on-board TCXO (the external-reference input is the hook);
  3. **cm-level relative node positions** (RTK GPS) to compute the steering phase
     gradient;
  4. **per-node TX phase calibration** (cable/PA/antenna, tracked over temperature);
  5. a **low-latency feedback/control channel** to close the loop.

Pragmatic path: do **coordinated** (time-aligned) TX/RX now via the scheduling
above, and **coherent-on-receive** in post-processing; treat coherent-TX
beamforming as a long-horizon goal gated on a shared phase reference.
