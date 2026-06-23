#!/usr/bin/env python3
"""analyze.py - turn a PPS_DELTA capture into stability metrics + figures.

Input CSV (from capture_pps_delta.sh): one line per GPS PPS edge,
    pps_seq,pps_delta
where pps_delta is AD936x sample-clock counts latched in one GPS second.

Produces (in --figdir):
  <prefix>_freq_offset_ppm.png   fractional frequency offset vs time
  <prefix>_delta_hist.png        per-second PPS_DELTA distribution (jitter)
  <prefix>_allan.png             overlapping Allan deviation sigma_y(tau)
  <prefix>_time_error.png        cumulative time error (clock drift) vs time
and prints a stats summary (also written to <csv>.stats.md).

Run with the host venv that has numpy+matplotlib, e.g.:
  ~/.venv-pluto/Scripts/python.exe analyze.py data/baseline_precorrection.csv \
      --label "pre-correction (baseline)" --prefix baseline
"""
import argparse, os, re, sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE_HZ = 30_720_000  # AD936x default rate; l_clk is this x{0.5,1,2,4} depending on mode


def detect_nominal(delta_median):
    """Snap the captured rate to the 30.72M-family nominal (1x in 1r1t, 2x in 2r2t)."""
    mult = min((0.5, 1, 2, 4), key=lambda k: abs(delta_median / BASE_HZ - k))
    return BASE_HZ * mult


def read_header_nominal(path):
    """Read '# nominal=<N>' emitted by the capture scripts, if present."""
    with open(path) as f:
        for line in f:
            if not line.startswith("#"):
                break
            m = re.search(r"nominal=(\d+)", line)
            if m:
                return float(m.group(1))
    return None


def overlapping_adev(y, tau0=1.0):
    """Overlapping Allan deviation from fractional-frequency samples y.
    Returns (taus, adev). Uses the phase-data estimator."""
    y = np.asarray(y, float)
    x = np.concatenate(([0.0], np.cumsum(y))) * tau0  # phase (seconds)
    Np = len(x)
    taus, devs = [], []
    m = 1
    while m <= (Np - 1) // 3:
        tau = m * tau0
        d = x[2 * m:] - 2 * x[m:-m] + x[:-2 * m]
        sig2 = np.sum(d * d) / (2 * (len(d)) * tau * tau)
        taus.append(tau)
        devs.append(np.sqrt(sig2))
        m *= 2
    return np.array(taus), np.array(devs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--nominal", type=float, default=None,
                    help="counts/sec (l_clk). Default: read '# nominal=' header, else auto-detect.")
    ap.add_argument("--label", default="pre-correction (baseline)")
    ap.add_argument("--prefix", default="baseline")
    ap.add_argument("--figdir", default=None)
    args = ap.parse_args()

    figdir = args.figdir or os.path.join(os.path.dirname(args.csv) or ".", "..", "figures")
    figdir = os.path.normpath(figdir)
    os.makedirs(figdir, exist_ok=True)

    seq, delta = [], []
    with open(args.csv) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            a, b = line.split(",")
            seq.append(int(a)); delta.append(int(b))
    seq = np.array(seq, dtype=np.int64)
    delta = np.array(delta, dtype=np.float64)
    if len(delta) < 4:
        sys.exit(f"need >=4 samples, got {len(delta)}")

    # unwrap 32-bit PPS_SEQ if it rolled; time axis in seconds from start
    seq = seq - seq[0]
    seq = np.where(np.diff(np.concatenate(([0], seq))) < 0, np.nan, seq)
    gaps = int(np.sum(np.diff(np.sort(np.unique(seq))) != 1))
    t = np.arange(len(delta))  # one sample per captured edge

    # nominal rate: CLI override > capture header > auto-detect from the data
    if args.nominal is not None:
        nom, nsrc = args.nominal, "CLI"
    else:
        hdr = read_header_nominal(args.csv)
        if hdr is not None:
            nom, nsrc = hdr, "header"
        else:
            nom, nsrc = detect_nominal(np.median(delta)), "auto-detected from data"
    print(f"nominal: {nom:,.0f} Hz ({nsrc}; l_clk = {nom/BASE_HZ:g}x the 30.72M base rate)")
    y = (delta - nom) / nom            # fractional frequency offset
    ppm = y * 1e6
    ns_per_count = 1e9 / nom

    mean_ppm = ppm.mean()
    std_ppm = ppm.std(ddof=1)
    p2p_counts = delta.max() - delta.min()
    std_ns = delta.std(ddof=1) * ns_per_count
    # cumulative time error (seconds): each second the clock gains y[i] seconds
    cum_time_us = np.cumsum(y) * 1e6
    drift_us_per_s = mean_ppm  # 1 ppm == 1 us/s
    taus, adev = overlapping_adev(y, tau0=1.0)

    stats = []
    def S(s): stats.append(s); print(s)
    S(f"# Stats: {args.label}")
    S(f"samples            : {len(delta)}  (gaps in PPS_SEQ: {gaps})")
    S(f"nominal            : {nom:,.0f} Hz")
    S(f"mean PPS_DELTA     : {delta.mean():,.2f} counts/s")
    S(f"freq offset (mean) : {mean_ppm:+.3f} ppm   ({delta.mean()-nom:+.1f} counts/s)")
    S(f"freq offset (std)  : {std_ppm:.4f} ppm")
    S(f"jitter p2p         : {p2p_counts:.0f} counts = {p2p_counts*ns_per_count:.1f} ns")
    S(f"jitter RMS         : {std_ns:.1f} ns ({delta.std(ddof=1):.3f} counts)")
    S(f"time-error slope   : {drift_us_per_s:+.3f} us/s  (=> {drift_us_per_s*86400/1e3:+.2f} ms/day)")
    S(f"ADEV @1s           : {adev[0]:.2e}")
    if len(taus) > 1:
        S(f"ADEV @{int(taus[-1])}s : {adev[-1]:.2e}")
    statpath = args.csv + ".stats.md"
    with open(statpath, "w") as f:
        f.write("```\n" + "\n".join(stats) + "\n```\n")

    # ---- figures ----
    L = args.label
    def save(name):
        p = os.path.join(figdir, f"{args.prefix}_{name}.png")
        plt.tight_layout(); plt.savefig(p, dpi=130); plt.close(); print("wrote", p)

    plt.figure(figsize=(8, 3.2))
    plt.plot(t, ppm, lw=0.9)
    plt.axhline(mean_ppm, color="C3", ls="--", lw=1, label=f"mean {mean_ppm:+.2f} ppm")
    plt.xlabel("time (s)"); plt.ylabel("freq offset (ppm)")
    plt.title(f"AD936x sample-clock frequency offset vs GPS - {L}")
    plt.legend(); plt.grid(alpha=.3); save("freq_offset_ppm")

    plt.figure(figsize=(5.2, 3.4))
    # robust window so a re-tune relock transient doesn't squash the main cluster
    med = np.median(delta)
    lo = int(min(delta.min(), med - 8)); hi = int(max(delta.max(), med + 8))
    lo = int(max(lo, med - 8)); hi = int(min(hi, med + 8))
    nout = int(np.sum((delta < lo) | (delta > hi)))
    bins = np.arange(lo - 0.5, hi + 1.5, 1.0)
    plt.hist(np.clip(delta, lo, hi), bins=bins, color="C0", edgecolor="k", lw=.4)
    plt.xlabel("PPS_DELTA (counts / GPS second)"); plt.ylabel("count")
    ttl = f"Per-second latch distribution - {L}"
    if nout:
        ttl += f"\n({nout} re-tune transient(s) clipped to edge)"
    plt.title(ttl)
    plt.grid(alpha=.3); save("delta_hist")

    plt.figure(figsize=(5.6, 3.8))
    plt.loglog(taus, adev, "o-", lw=1)
    plt.xlabel("averaging time tau (s)"); plt.ylabel("overlapping Allan deviation $\\sigma_y(\\tau)$")
    plt.title(f"Allan deviation - {L}")
    plt.grid(alpha=.3, which="both"); save("allan")

    plt.figure(figsize=(8, 3.2))
    plt.plot(t, cum_time_us, lw=1.1, color="C1")
    plt.xlabel("time (s)"); plt.ylabel("cumulative time error (us)")
    plt.title(f"Uncorrected clock drift ({drift_us_per_s:+.2f} us/s) - {L}")
    plt.grid(alpha=.3); save("time_error")

    print(f"\nstats written to {statpath}")


if __name__ == "__main__":
    main()
