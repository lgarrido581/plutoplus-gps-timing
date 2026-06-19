#!/usr/bin/env python3
"""compare.py - overlay before/after PPS_DELTA captures (xo_correction off vs on).

  python compare.py data/baseline_precorrection.csv data/corrected_postcorrection.csv

Produces in figures/:
  compare_freq_offset_ppm.png   frequency offset vs time, both runs
  compare_time_error.png        cumulative time error, both runs (the headline)
  compare_allan.png             Allan deviation, both runs
  compare_hist.png              steady-state per-second distribution, both runs
and prints a markdown before/after table.

A "re-tune transient" (a single GPS second caught during a PLL relock when the
loop nudged xo_correction) is excluded from steady-state jitter stats and
despiked for the Allan deviation; it is kept (and visible) in the time series.
"""
import argparse, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

NOMINAL = 30_720_000
TRANSIENT = 50  # |delta-NOMINAL| > this (counts, ~1.6 ppm) = re-tune relock sample


def load(path):
    d = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                d.append(int(line.split(",")[1]))
    return np.array(d, float)


def adev(y, tau0=1.0):
    x = np.concatenate(([0.0], np.cumsum(y))) * tau0
    Np = len(x); taus = []; devs = []; m = 1
    while m <= (Np - 1) // 3:
        tau = m * tau0
        diff = x[2 * m:] - 2 * x[m:-m] + x[:-2 * m]
        devs.append(np.sqrt(np.sum(diff * diff) / (2 * len(diff) * tau * tau)))
        taus.append(tau); m *= 2
    return np.array(taus), np.array(devs)


def stats(delta):
    err = delta - NOMINAL
    # a transient is a sample far from THIS run's own median (a PLL relock during
    # an xo_correction write), not from nominal -- the baseline's offset is real.
    med = np.median(delta)
    inlier = np.abs(delta - med) <= TRANSIENT
    n_tr = int(np.sum(~inlier))
    ei = err[inlier]
    # despiked copy for ADEV / drift slope: replace transients with inlier median
    ed = err.copy(); ed[~inlier] = np.median(ei)
    y = ed / NOMINAL
    taus, ad = adev(y)
    return dict(
        n=len(delta), n_tr=n_tr,
        mean_ppm=ei.mean() / NOMINAL * 1e6,
        std_ppm=ei.std(ddof=1) / NOMINAL * 1e6,
        p2p_cnt=int(ei.max() - ei.min()),
        p2p_ns=(ei.max() - ei.min()) * 1e9 / NOMINAL,
        drift_us_s=ed.mean() / NOMINAL * 1e6,    # despiked mean = sustained slope
        cum_us=np.cumsum((delta - NOMINAL) / NOMINAL) * 1e6,   # full (honest)
        taus=taus, adev=ad, err=err,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("before"); ap.add_argument("after")
    ap.add_argument("--figdir", default="figures")
    a = ap.parse_args()
    os.makedirs(a.figdir, exist_ok=True)

    B = stats(load(a.before)); A = stats(load(a.after))
    tb = np.arange(B["n"]); ta = np.arange(A["n"])

    def row(name, b, aa):
        print(f"| {name} | {b} | {aa} |")
    print("\n| Metric | Pre-correction | Post-correction |")
    print("|---|---|---|")
    row("Mean frequency offset", f"{B['mean_ppm']:+.3f} ppm", f"{A['mean_ppm']:+.3f} ppm")
    row("Frequency stability (std)", f"{B['std_ppm']:.3f} ppm", f"{A['std_ppm']:.3f} ppm")
    row("Per-second jitter (p2p)", f"{B['p2p_cnt']} cnt / {B['p2p_ns']:.0f} ns",
        f"{A['p2p_cnt']} cnt / {A['p2p_ns']:.0f} ns")
    row("Time-error drift rate", f"{B['drift_us_s']:+.3f} us/s ({B['drift_us_s']*86.4:+.0f} ms/day)",
        f"{A['drift_us_s']:+.3f} us/s ({A['drift_us_s']*86.4:+.1f} ms/day)")
    row("Cumulative time error (end)", f"{B['cum_us'][-1]:+.0f} us over {B['n']} s",
        f"{A['cum_us'][-1]:+.1f} us over {A['n']} s")
    row("Allan dev @1s / @longest", f"{B['adev'][0]:.1e} / {B['adev'][-1]:.1e}",
        f"{A['adev'][0]:.1e} / {A['adev'][-1]:.1e}")
    row("Re-tune transients", f"{B['n_tr']}", f"{A['n_tr']}")

    def save(name):
        p = os.path.join(a.figdir, f"compare_{name}.png")
        plt.tight_layout(); plt.savefig(p, dpi=130); plt.close(); print("wrote", p)

    plt.figure(figsize=(8.4, 3.3))
    plt.plot(tb, B["err"] / NOMINAL * 1e6, lw=.8, label="pre-correction")
    plt.plot(ta, A["err"] / NOMINAL * 1e6, lw=.8, label="post-correction")
    plt.axhline(0, color="k", lw=.5)
    plt.xlabel("time (s)"); plt.ylabel("freq offset (ppm)")
    plt.title("AD936x sample-clock frequency offset vs GPS"); plt.legend(); plt.grid(alpha=.3)
    save("freq_offset_ppm")

    plt.figure(figsize=(8.4, 3.3))
    plt.plot(tb, B["cum_us"], lw=1.3, label=f"pre  ({B['drift_us_s']:+.2f} us/s)")
    plt.plot(ta, A["cum_us"], lw=1.3, label=f"post ({A['drift_us_s']:+.3f} us/s)")
    plt.axhline(0, color="k", lw=.5)
    plt.xlabel("time (s)"); plt.ylabel("cumulative time error (us)")
    plt.title("Uncorrected vs disciplined sample-clock drift"); plt.legend(); plt.grid(alpha=.3)
    save("time_error")

    plt.figure(figsize=(5.8, 4.0))
    plt.loglog(B["taus"], B["adev"], "o-", lw=1, label="pre-correction")
    plt.loglog(A["taus"], A["adev"], "s-", lw=1, label="post-correction")
    plt.xlabel("averaging time tau (s)"); plt.ylabel(r"overlapping Allan deviation $\sigma_y(\tau)$")
    plt.title("Allan deviation - before / after"); plt.legend(); plt.grid(alpha=.3, which="both")
    save("allan")

    plt.figure(figsize=(7.0, 3.6))
    inl = []
    for d in (B["err"], A["err"]):
        inl.append(d[np.abs(d - np.median(d)) <= TRANSIENT])
    lo = int(min(inl[0].min(), inl[1].min())) - 1
    hi = int(max(inl[0].max(), inl[1].max())) + 1
    bins = np.arange(lo - .5, hi + 1.5, 1)
    plt.hist(inl[0], bins=bins, alpha=.6, label="pre-correction", color="C0", edgecolor="k", lw=.3)
    plt.hist(inl[1], bins=bins, alpha=.6, label="post-correction", color="C1", edgecolor="k", lw=.3)
    plt.axvline(0, color="k", lw=.6, ls="--")
    plt.xlabel("frequency error (counts vs nominal,  1 count = 0.033 ppm = 33 ns)")
    plt.ylabel("count")
    plt.title("Steady-state per-second distribution (re-tune transients excluded)")
    plt.legend(); plt.grid(alpha=.3); save("hist")


if __name__ == "__main__":
    main()
