# TDOA tooling (work in progress)

Scripts for building a GPS‑synchronized, multi‑node TDOA network from GPS‑timed Plutos.

## ⚠️ Key fact about Pluto timestamps

The Pluto's IQ stream has **no hardware‑embedded per‑sample timestamp** — it's raw interleaved
`int16` I/Q. A "timestamp" is something you **attach in software at capture time**, stamped from the
(GPS‑disciplined) system clock. Two limits follow:

1. **System clock ≠ sample clock.** chrony/PPS disciplines `CLOCK_REALTIME`, *not* the AD9363 sample
   clock (a free‑running 40 MHz TCXO). For TDOA you also need to **frequency‑lock the sample clock**
   to GPS (feed a GPSDO 10 MHz into the Pluto+ external reference input).
2. **USB jitter.** Software buffer‑arrival timestamps are jittery at the ms level — fine for coarse
   capture windowing, useless for fine TDOA (1 µs ≈ 300 m). Fine alignment needs a **PPS marker
   injected into RX** or a **shared reference signal** cross‑correlated across nodes.

## Scripts

| Script | Runs on | Timestamp source | Use |
|---|---|---|---|
| `capture_gps_timestamped.sh` | **the Pluto** | GPS‑disciplined `CLOCK_REALTIME` | prove a GPS‑true timestamp can be attached to a capture |
| `capture_timestamp.py` | a host PC (`pip install pyadi-iio numpy`) | host clock (NTP‑sync to the Pluto for GPS time) | richer capture + numpy analysis |

```sh
# On the Pluto:
./capture_gps_timestamped.sh 100000000 2000000 262144 /tmp/cap.iq

# On a host PC:
python capture_timestamp.py ip:pluto.local
```

The raw `.iq` is interleaved `int16` (I, Q, I, Q, …). To load in numpy:
```python
import numpy as np
raw = np.fromfile("cap.iq", dtype=np.int16)
iq = raw[0::2] + 1j * raw[1::2]
```

## Roadmap (see top-level discussion)

1. **Frequency lock** each node's sample clock to GPS (GPSDO 10 MHz → Pluto+ ext ref). *Essential.*
2. **Coarse time sync** — GPS/PPS/chrony (done) → all nodes capture the same GPS‑second window.
3. **Fine alignment** — cross‑correlate a shared reference signal (à la RTL‑SDR‑TDOA) to remove
   residual inter‑node offset, then cross‑correlate the target → TDOA → multilateration.

### Validation tests
- **T1 — sample‑clock frequency:** samples between two PPS edges should equal `fs` exactly (locked).
- **T2 — absolute timestamp accuracy:** inject GPS PPS (or a PPS‑gated burst) into RX, find its
  sample index, compare its computed time to the GPS whole‑second. Error = timestamp accuracy.
- **T3 — two‑node coherence:** feed both Plutos the same signal; cross‑correlate → measured TDOA
  should be ~0 and *stable* (drifts without the GPSDO lock, holds with it).
