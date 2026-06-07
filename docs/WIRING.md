# Wiring reference

Connect the GPS module to the Pluto+ expansion header. The table uses **MIO
numbers** — map those to your board's physical header pins (Pluto+ header
layouts vary by revision, so check your board's pinout).

## Connections

| GPS pin | Pluto+ function | MIO | Direction | Notes |
|---|---|---|---|---|
| **PPS** | `pps-gpio` | **MIO9** | → into Pluto | rising edge → `/dev/pps0` |
| **TX** (GPS out) | UART1 **RX** | **MIO13** | → into Pluto | NMEA into the Pluto |
| **RX** (GPS in) | UART1 **TX** | **MIO12** | ← from Pluto | optional (only to configure the GPS) |
| **GND** | GND | — | — | must be common |
| **VCC** | 3V3 | — | power | a real 3V3 rail — **not** an MIO pin |

```
   GPS module                              Pluto+
 ┌────────────┐                      ┌────────────────────┐
 │  VCC ───────┼──── 3V3 ────────────┤ 3V3                 │
 │  GND ───────┼──── GND ────────────┤ GND                 │
 │  TX  ───────┼─────────────────────► MIO13   (UART1 RX)  │   NMEA in
 │  RX  ◄──────┼─────────────────────┤ MIO12   (UART1 TX)  │   (optional)
 │  PPS ───────┼─────────────────────► MIO9    (pps-gpio)  │   1 Hz pulse
 └────────────┘                      └────────────────────┘
   antenna ↑
   keep FAR from the Pluto (RF/EMI desense); open sky; patch facing up
```

## Gotchas

- **TX/RX swap is the #1 mistake** — GPS **TX → MIO13**. Wrong way = silence on the port.
- **Don't power the GPS from an MIO pin** — use a real 3V3 rail; MIO pins source only a few mA.
- The NMEA port is **`/dev/ttyPS0`**, not `ttyPS1` (UART0 is disabled; UART1 owns the `serial0`
  alias).
- **U-Boot console is on UART1** — the GPS NMEA stream will abort autoboot unless `bootdelay=-2`
  is set (the firmware's `S30bootdelay` does this; first boot on a fresh env must have GPS TX
  disconnected — see [`../README.md`](../README.md) *Gotchas*).
- **Antenna placement dominates reception.** A receiver next to the Pluto often sees 1–2 satellites
  and never locks; move the antenna away (long-cable active antenna at a window/outside). You need
  **≥4 satellites** for a fix.

## Levels

This is a **3V3** board (Pluto+ V2). Use a **3V3** GPS module / logic levels. Don't drive 5V logic
into the MIO pins.
