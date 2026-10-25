/*
 * capture_core.c - see capture_core.h. Refactor of the validated DSN/sdr-stack
 * device/streamer/iq_capture.c into an in-memory, single-shot capture callable by
 * the pluto_ctld :5562 ZMQ server. The tune + axi_tdd PPS-gated arm + single-DMA
 * contiguous refill + pps_counter anchor (incl. the sample-exact DMA-start latch
 * with a frame-grid fallback) are preserved from the validated tool; the changes
 * are: argv -> capture_req_t, SigMF files -> in-memory meta+IQ, plus a §7 rate cap,
 * t0_gps scheduling, and core:frequency = the AD9361 LO read back.
 */
#define _POSIX_C_SOURCE 199309L
#include "capture_core.h"
#include "pps_timestamp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <iio.h>

#define LCLK_FALLBACK_HZ 122880000.0 /* accepts LibreSDR's validated 4x l_clk */
#define PLUTO_LCLK_MAX_HZ 61440000.0
#define LIBRE_LCLK_MAX_HZ 122880000.0
#define TDD_V2_PATH "/sys/bus/platform/devices/7c440000.tdd"
#define WINDOW_MARGIN_S 0.010    /* the PPS window stays open this long (+4096 samples)
                                  * past the end of the capture */
#define MAX_BLOCK_PATH "/sys/module/industrialio_buffer_dma/parameters/max_block_size"
#define ARM_LEAD_S  0.35         /* release the PPS window into the RX DMA no earlier than
                                  * this before t0 (later for a long window, once the
                                  * previous second's window has closed), so the capture
                                  * gates on the first PPS at/after (t0 - ARM_LEAD_S); used
                                  * by BOTH the release and the Level-1 integer-second
                                  * anchor -- a single constant so they cannot drift. */
#define CNT_TOL 0.001            /* a settled PPS_DELTA is within 1000 ppm of l_clk_multiple x
                                  * rate: the XO is held within ~25 ppm, but the second after
                                  * a sample-rate change counts a mix of the old and new rates
                                  * (seen 25.72 M for 25.00 M) */

static struct iio_device *g_tdd = NULL;
static int g_tdd_v2 = 0;
static int g_lclk_multiple = 0;  /* last multiple a settled PPS_DELTA confirmed (the channel
                                  * mode is fixed at boot); 0 = none yet */

static int sysfs_write(const char *name, long long value) {
    char path[256];
    snprintf(path, sizeof path, "%s/%s", TDD_V2_PATH, name);
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    int rc = fprintf(f, "%lld\n", value) < 0 ? -2 : 0;
    if (fclose(f) != 0 && rc == 0) rc = -3;
    return rc;
}

/* Coincident (PPS-anchored) capture. With sync_ext ALONE (CONTROL=0x9), ADI's axi_tdd re-syncs
 * sync_in only ONCE at enable then free-runs -- its window drifts and cannot align across nodes.
 * (The sync_reset bit, CONTROL=0xB, DOES re-anchor per pulse -- HDL axi_tdd_counter.sv:
 * `if (tdd_sync && tdd_sync_rst) tdd_counter<=0` -- but it zeroes the counter mid-frame, so a PPS
 * off a frame boundary makes a runt frame -> truncated capture. So we anchor via pps_counter's
 * window, which owns the boundary.) The BD ORs axi_tdd/tdd_channel_1 with pps_counter/tdd_enable into
 * the RX-DMA sync (each DMA segment starts on a sample with the sync HIGH); pps_counter
 * resets its frame to 0 on EVERY PPS edge. So for a gated capture we DISABLE axi_tdd --
 * which holds tdd_channel_1 at its latched polarity, made LOW first (configure_tdd: the
 * boot default is HIGH) -- and let pps_counter own the OR
 * via its PPS-anchored window (programmed by the caller with pps_ts_config_frame). The
 * window then opens coincident across nodes. restore_rx_mode() re-opens axi_tdd for
 * free-running streaming RX. TDD raw counts are in sample-clock (fs) units. */
/* A synced axi_tdd (sync_soft or a sync source) is RUNNING (state 3) with burst_count 0 and
 * can't be disabled: enable 0 reads back 0, but the core keeps running and its channels keep
 * their window, taking channel changes only at a frame end -- so channel 1 can't be held LOW
 * and a gated capture would start as soon as its buffer is queued. Park it: with the core
 * enabled a one-frame burst ends the run at the next frame end, then enable 0 leaves it IDLE.
 * Verified on node1 (2026-10-25). Returns 0 when not running or parked, -1 if it still runs. */
static int tdd_park(double timeout_s) {
    long long st = -1;
    if (iio_device_attr_read_longlong(g_tdd, "state", &st) < 0 || st != 3) return 0;
    iio_device_attr_write(g_tdd, "enable", "1");
    iio_device_attr_write(g_tdd, "burst_count", "1");
    iio_device_attr_write(g_tdd, "enable", "0");
    struct timespec t0, now, pause = { 0, 20000000L };
    clock_gettime(CLOCK_MONOTONIC, &t0);
    do {
        nanosleep(&pause, NULL);
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (iio_device_attr_read_longlong(g_tdd, "state", &st) < 0) break;
    } while (st == 3 && (double)(now.tv_sec - t0.tv_sec) +
                        (double)(now.tv_nsec - t0.tv_nsec) / 1e9 < timeout_s);
    iio_device_attr_write(g_tdd, "burst_count", "0");
    return st == 3 ? -1 : 0;
}

static int configure_tdd(struct iio_context *ctx) {
    g_tdd = iio_context_find_device(ctx, "iio-axi-tdd-0");
    g_tdd_v2 = 0;
    /* A disabled axi_tdd drives each channel at its LATCHED polarity, which stays the
     * synthesis default until the core has run: ch1 (the RX-DMA sync) defaults HIGH on
     * Pluto (TDD_DEFAULT_POL 0b010), so after boot the OR would hold the gate open and
     * the first gated capture would start as soon as its buffer is queued. Run the core
     * once with ch1 off at polarity 0, so disabling it latches ch1 LOW. */
    if (!g_tdd && access(TDD_V2_PATH "/enable", F_OK) == 0) {
        g_tdd_v2 = 1;
        sysfs_write("out_channel1_polarity", 0);
        sysfs_write("out_channel1_enable", 0);
        sysfs_write("enable", 1);
        return sysfs_write("enable", 0); /* ch1 LOW: yield the OR to pps_counter */
    }
    if (!g_tdd) return -1;
    if (tdd_park(2.5) != 0) return -2;
    struct iio_channel *ch1 = iio_device_find_channel(g_tdd, "channel1", true);
    if (ch1) {
        /* From disabled, so enable 1 below is a real transition: restore_rx_mode leaves
         * the core enabled (ARMED), and writing enable 1 again would not latch polarity
         * 0 -- ch1 would stay HIGH and the capture would start ungated. */
        iio_device_attr_write(g_tdd, "enable", "0");
        iio_channel_attr_write(ch1, "polarity", "0");
        iio_channel_attr_write(ch1, "enable", "0");
        iio_device_attr_write(g_tdd, "enable", "1");
    }
    /* iio_device_attr_write returns the BYTE COUNT on success (not 0); the caller
     * checks != 0, so returning it raw read every success as failure. Normalize. */
    return iio_device_attr_write(g_tdd, "enable", "0") < 0 ? -1 : 0;
}

/* Restore free-running streaming RX WITHOUT a reboot. A gated capture disabled axi_tdd (to
 * yield the RX-DMA OR to pps_counter); hold channel1 HIGH again so the OR is HIGH and the
 * RX DMA captures freely, and drop pps_counter's window so only axi_tdd gates streaming. */
static void restore_rx_mode(long long frame_len, long long rate) {
    if (g_tdd_v2) {
        long long flen = frame_len > 1 ? frame_len : rate;
        sysfs_write("enable", 0);
        sysfs_write("frame_length_raw", flen - 1);
        sysfs_write("out_channel1_on_raw", 0);
        /* One low clock at the frame boundary guarantees the next DMA-start edge. */
        sysfs_write("out_channel1_off_raw", flen - 1);
        sysfs_write("out_channel1_polarity", 0);
        sysfs_write("out_channel1_enable", 1);
        sysfs_write("enable", 1);
        pps_ts_disable_frame();
        return;
    }
    if (g_tdd) {
        /* Steady HIGH, as after boot: with channel 1 off, the core drives ch1 at its
         * polarity, which latches across the enable transition. A full-open window
         * (on 0, off = frame) did not do this: enabled without a sync the core sits ARMED
         * with every channel LOW, so ungated captures after a gated one never started. */
        struct iio_channel *ch1 = iio_device_find_channel(g_tdd, "channel1", true);
        iio_device_attr_write(g_tdd, "enable", "0");
        if (ch1) {
            iio_channel_attr_write(ch1, "enable", "0");
            iio_channel_attr_write(ch1, "polarity", "1");
        }
        iio_device_attr_write(g_tdd, "enable", "1");      /* ch1 HIGH -> OR HIGH -> streaming RX */
    }
    pps_ts_disable_frame();   /* tdd_enable -> 0: axi_tdd alone gates streaming */
}

/* ISO8601 UTC with ns, e.g. 2026-06-23T18:04:05.123456789Z */
static void iso8601_ns(uint64_t gps_ns, char *out, size_t n) {
    time_t sec = (time_t)(gps_ns / 1000000000ULL);
    unsigned long frac = (unsigned long)(gps_ns % 1000000000ULL);
    struct tm tmv;
    gmtime_r(&sec, &tmv);
    size_t k = strftime(out, n, "%Y-%m-%dT%H:%M:%S", &tmv);
    snprintf(out + k, n - k, ".%09luZ", frac);
}

static int fail(capture_result_t *out, const char *msg) {
    snprintf(out->err, sizeof out->err, "%s", msg);
    return -1;
}

/* The DMA buffer and context behind a successful capture (see capture_release). */
struct capture_handle {
    struct iio_buffer  *buf;
    struct iio_context *ctx;
};

void capture_release(capture_result_t *out) {
    struct capture_handle *h = (struct capture_handle *)out->priv;
    if (h) {
        if (h->buf) iio_buffer_destroy(h->buf);
        if (h->ctx) iio_context_destroy(h->ctx);
        free(h);
    }
    free(out->meta_json);
    out->priv = NULL; out->meta_json = NULL; out->iq = NULL; out->iq_len = 0;
}

static double realtime_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static double mono_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}

/* The kernel's per-DMA-block cap (bytes), or 0 if unreadable. A gap-free capture
 * is one block; S66ctld raises the 64 MiB default so ~1 s at 30.72 MS/s fits. */
static long long max_block_bytes(void) {
    long long v = 0;
    FILE *f = fopen(MAX_BLOCK_PATH, "r");
    if (f) { if (fscanf(f, "%lld", &v) != 1) v = 0; fclose(f); }
    return v;
}

long long capture_block_cap(void) { return max_block_bytes(); }

int capture_run(const capture_req_t *req, capture_result_t *out) {
    out->meta_json = NULL; out->iq = NULL; out->iq_len = 0; out->priv = NULL;
    out->err[0] = '\0';

    if (req->rate_hz <= 0 || req->samples == 0 || req->freq_hz <= 0)
        return fail(out, "bad request (freq_hz/sample_rate_hz/samples)");

    struct iio_context *ctx = iio_create_local_context();
    if (!ctx) return fail(out, "no local iio context");

    struct iio_device *phy = iio_context_find_device(ctx, "ad9361-phy");
    struct iio_device *rx  = iio_context_find_device(ctx, "cf-ad9361-lpc");
    struct iio_channel *p_rx = phy ? iio_device_find_channel(phy, "voltage0", false) : NULL;
    struct iio_channel *p_lo = phy ? iio_device_find_channel(phy, "altvoltage0", true) : NULL;
    if (!phy || !rx || !p_rx || !p_lo) {
        iio_context_destroy(ctx);
        return fail(out, "ad9361 devices/channels not found");
    }

    /* --- §7 channel-mode rate cap. l_clk = interface_multiple * sample_rate; refuse any
     * requested rate whose l_clk would overrun the AD9361 interface (-> DMA wedge).
     * Detect the multiple from the live counter (PPS_DELTA) vs the sysfs rate.
     * Pluto+ is normally 1x/2x with a 61.44 MHz ceiling; LibreSDR's validated
     * 2R2T LVDS design is 4x with a 122.88 MHz ceiling. */
    pps_ts_t pps;
    int have_pps = (pps_ts_init(&pps, LCLK_FALLBACK_HZ) == 0);
    long long cur_rate = 0;
    iio_channel_attr_read_longlong(p_rx, "sampling_frequency", &cur_rate);
    /* conservative Pluto+ fallback, or the last multiple a settled count confirmed */
    int lclk_multiple = g_lclk_multiple ? g_lclk_multiple : 2;
    if (have_pps) {
        uint32_t cnt = pps_ts_cnt_hz(&pps);
        if (cnt > 0 && cur_rate > 0) {
            long long r = ((long long)cnt + cur_rate / 2) / cur_rate;  /* round */
            /* Only a settled count decides: within ~2 s of a rate change PPS_DELTA still
             * counts the old rate, or a mix, and can round to the wrong multiple. */
            double dev = (double)cnt - (double)(r * cur_rate);
            if (dev < 0.0) dev = -dev;
            if (r >= 1 && r <= 4 && dev <= CNT_TOL * (double)(r * cur_rate))
                lclk_multiple = g_lclk_multiple = (int)r;
        }
    }
    double lclk_max = lclk_multiple > 2 ? LIBRE_LCLK_MAX_HZ : PLUTO_LCLK_MAX_HZ;
    double max_rate = lclk_max / (double)lclk_multiple;
    if (max_rate > 61440000.0) max_rate = 61440000.0; /* AD936x sample-rate limit */
    if ((double)req->rate_hz > max_rate) {
        char m[160];
        snprintf(m, sizeof m, "sample_rate_hz %lld exceeds %.0f for l_clk multiple %d",
                 req->rate_hz, max_rate, lclk_multiple);
        if (have_pps) pps_ts_close(&pps);
        iio_context_destroy(ctx);
        return fail(out, m);
    }

    /* Refuse an impossible t0 before touching the radio. Whether a valid one leaves
     * enough time for the retune and the PPS wait is checked after them. */
    if (req->tdd_sync && req->have_t0) {
        double ahead = req->t0_gps - realtime_s() - ARM_LEAD_S;
        if (ahead <= 0.0 || ahead >= 60.0) {
            if (have_pps) pps_ts_close(&pps);
            iio_context_destroy(ctx);
            return fail(out, "t0_gps must be 0.35 to 60 seconds in the future");
        }
    }

    /* Prove liveness once per request by observing a new PPS edge. A gated capture
     * waits for it after the retune, with its frame programmed, so that the edge
     * anchors the frame (below); the rest wait here, before tuning. */
    int live_pps = 0;
    if (have_pps && req->require_gps && !req->tdd_sync)
        live_pps = pps_ts_live(&pps, 1.5);

    /* --require-gps: refuse un-anchored data when a live PPS is demanded. */
    if (req->require_gps && !req->tdd_sync && !live_pps) {
        if (have_pps) pps_ts_close(&pps);
        iio_context_destroy(ctx);
        return fail(out, "not GPS-trusted (pps_present=false)");
    }

    /* nominal cnt_clk for this capture's mode (drives xo_ppm + the anchor fallback). */
    double nominal_cnt = (double)lclk_multiple * (double)req->rate_hz;
    pps.nominal_cnt_hz = nominal_cnt;
    pps.cnt_tol = CNT_TOL;

    /* --- tune RX0: rate + bandwidth + gain on phy voltage0(in), LO on altvoltage0. */
    iio_channel_attr_write_longlong(p_rx, "sampling_frequency", req->rate_hz);
    iio_channel_attr_write_longlong(p_rx, "rf_bandwidth", req->rate_hz);
    if (req->have_gain) {
        iio_channel_attr_write(p_rx, "gain_control_mode", "manual");
        iio_channel_attr_write_double(p_rx, "hardwaregain", req->gain_db);
    } else {
        iio_channel_attr_write(p_rx, "gain_control_mode", "slow_attack");
    }
    iio_channel_attr_write_longlong(p_lo, "frequency", req->freq_hz);

    /* core:frequency MUST be the ACTUAL chip LO read back (the AD9361 silently clamps
     * an out-of-range LO and holds its old value); DSN trusts this over the request. */
    long long actual_lo = req->freq_hz;
    iio_channel_attr_read_longlong(p_lo, "frequency", &actual_lo);

    /* Enable the RX0 I/Q pair on the capture device. */
    struct iio_channel *i0 = iio_device_find_channel(rx, "voltage0", false);
    struct iio_channel *q0 = iio_device_find_channel(rx, "voltage1", false);
    if (!i0 || !q0) {
        if (have_pps) pps_ts_close(&pps);
        iio_context_destroy(ctx);
        return fail(out, "rx I/Q channels not found");
    }
    iio_channel_enable(i0);
    iio_channel_enable(q0);

    const char *method = "live_count_at_refill";
    long long frame_len = 0;
    long long off_raw = 0;
    double window_end_s = 0.0;   /* RX window close, seconds after its frame start */
    double edge_s = 0.0;         /* t0 path: the PPS second sample 0 is gated to */
    int armed = 0;
    uint32_t lseq_prev = 0;

    if (req->tdd_sync) {
        method = "tdd_pps_window";
        const char *no_pps = req->require_gps ? "not GPS-trusted (pps_present=false)"
                                              : "tdd_sync needs a live GPS PPS (would wedge the DMA)";
        if (!have_pps) {
            iio_context_destroy(ctx);
            return fail(out, no_pps);
        }
        frame_len = lclk_multiple * req->rate_hz;  /* one GPS second in l_clk counts */
        /* pps_counter window [on_raw, off_raw): on_raw = offset_samples; off covers the
         * offset + the whole capture + a small margin, and must close >= 20 ms before
         * the next PPS (so that frame's window opens on a fresh edge). The DMA starts
         * each <=16 MB segment on a sample with its sync high, so the window must stay
         * open until the last segment has started; the margin covers that: 10 ms + 4096
         * samples. One capture therefore fits in just under a second (~0.97 s at offset
         * 0); it was 1.5x the capture (max ~0.65 s) before. */
        long long margin = (long long)((double)req->rate_hz * WINDOW_MARGIN_S) + 4096;
        long long on_raw = req->offset_samples * lclk_multiple;
        off_raw = (req->offset_samples + (long long)req->samples + margin) * lclk_multiple;
        long long setup_guard_raw = (long long)(nominal_cnt * 0.020);
        if (req->offset_samples < 0 ||
            off_raw >= frame_len - setup_guard_raw) {
            long long max_n = (frame_len - setup_guard_raw) / lclk_multiple - 1
                              - req->offset_samples - margin;
            char m[200];
            snprintf(m, sizeof m, "offset(%lld)+capture(%zu) does not fit the PPS second: "
                     "max %lld samples at this rate and offset", req->offset_samples,
                     req->samples, max_n > 0 ? max_n : 0);
            pps_ts_close(&pps);
            iio_context_destroy(ctx);
            return fail(out, m);
        }
        window_end_s = (double)off_raw / nominal_cnt;
        int tdd = configure_tdd(ctx);
        if (tdd != 0) {
            pps_ts_close(&pps);
            iio_context_destroy(ctx);
            return fail(out, tdd == -2 ? "axi_tdd is running (synced) and could not be parked"
                                       : "axi_tdd (iio-axi-tdd-0) not found");
        }
        /* Program pps_counter's PPS-anchored RX window [offset, off_raw). cnt_clk == the
         * AD936x sample clock (== l_clk), so these counts are the same sample units as the
         * axi_tdd path. The BD ORs tdd_enable into the RX-DMA sync; its output is held low
         * until the buffer exists (pps_ts_drive_in_gap below), then sample[0] lands on a
         * GPS-locked edge, coincident across nodes. */
        if (pps_ts_config_frame((uint32_t)frame_len, (uint32_t)on_raw,
                                (uint32_t)off_raw) != 0) {
            restore_rx_mode(frame_len, req->rate_hz);
            pps_ts_close(&pps);
            iio_context_destroy(ctx);
            return fail(out, "pps_counter frame config failed (/dev/mem)");
        }

        /* GUARD: arming the DMA without a window that WILL open wedges it (reboot to
         * clear). Require a live GPS PPS so pps_counter's PPS-anchored frame runs. With
         * the frame already programmed, that edge also anchors it: every later second
         * is PPS-anchored, so a window of any length closes before the gated edge. A
         * frame programmed after the wait started mid-second, and a long window could
         * not close in time; t0 then needed ~1 s more lead than a short one. */
        live_pps = pps_ts_live(&pps, 1.5);
        if (!live_pps) {
            restore_rx_mode(frame_len, req->rate_hz);
            pps_ts_close(&pps);
            iio_context_destroy(ctx);
            return fail(out, no_pps);
        }
        if (req->have_t0) {
            double ahead = req->t0_gps - realtime_s() - ARM_LEAD_S;
            if (ahead <= 0.0) {
                char m[200];
                snprintf(m, sizeof m, "t0_gps is %.2f s ahead after the retune and the PPS "
                         "wait; send it further ahead (the retune takes up to ~1.5 s when "
                         "the rate changes)", ahead + ARM_LEAD_S);
                restore_rx_mode(frame_len, req->rate_hz);
                pps_ts_close(&pps);
                iio_context_destroy(ctx);
                return fail(out, m);
            }
            /* The gated PPS second: the first PPS at/after t0 - ARM_LEAD_S (the same
             * rule the Level-1 anchor below uses). It comes after the edge just seen. */
            edge_s = (double)(long long)(req->t0_gps - ARM_LEAD_S);
            if (edge_s < req->t0_gps - ARM_LEAD_S) edge_s += 1.0;
        }
        iio_context_set_timeout(ctx, 4000);   /* a missed window errors, not hangs */

        /* Snapshot before the first arm. The old ordering armed here, then took
         * the snapshot after buffer creation; by then the capture latch had
         * already fired, forcing every result onto the software fallback. */
        pps_ts_latch(&pps, NULL, &lseq_prev, NULL);
        if (iio_device_attr_write(rx, "sync_start_enable", "arm") < 0) {
            restore_rx_mode(frame_len, req->rate_hz);
            pps_ts_close(&pps);
            iio_context_destroy(ctx);
            return fail(out, "sync_start_enable not settable");
        }
        armed = 1;
    }

    /* One iio_buffer_refill == ONE DMA block, gap-free internally, bounded by CMA and
     * the kernel's max_block_size (S66ctld raises it to 128 MiB = 1 s at 30.72 MS/s). */
    int rc = 0;
    long long block_cap = max_block_bytes();
    double t_alloc0 = mono_ms();
    /* ONE kernel block. libiio's default asks for four and the mmap path allocates as
     * many full-size blocks as CMA holds (2 x 118 MB for a 0.96 s capture), doubling the
     * memory and the allocation time for blocks that are never read. */
    iio_device_set_kernel_buffers_count(rx, 1);
    struct iio_buffer *buf = iio_device_create_buffer(rx, req->samples, false);
    if (!buf) {
        if (armed) { iio_device_attr_write(rx, "sync_start_enable", "disarm");
                     restore_rx_mode(frame_len, req->rate_hz); }
        pps_ts_close(&pps);
        iio_context_destroy(ctx);
        char m[200];
        snprintf(m, sizeof m, "create_buffer failed for %zu samples (%zu MB; DMA block cap "
                 "%lld MB, CMA) -- fewer samples or raise iio_max_block_size",
                 req->samples, req->samples * 4 / 1000000, block_cap / 1000000);
        return fail(out, m);
    }

    /* LibreSDR's RX DMA consumes the pre-buffer arm while the buffer is being
     * created. Re-arm the now-created transfer, but keep lseq_prev from before
     * the first arm so any capture edge remains detectably fresh. */
    if (armed && iio_device_attr_write(rx, "sync_start_enable", "arm") < 0) {
        iio_device_attr_write(rx, "sync_start_enable", "disarm");
        iio_buffer_destroy(buf);
        restore_rx_mode(frame_len, req->rate_hz);
        pps_ts_close(&pps);
        iio_context_destroy(ctx);
        return fail(out, "sync_start_enable re-arm failed");
    }
    double alloc_ms = mono_ms() - t_alloc0;

    /* Release the PPS window into the DMA sync only now that the buffer is queued, and
     * only while the window is closed (pps_ts_drive_in_gap): the DMA then starts on the
     * next window's rising edge -- the gated PPS -- which is also the edge the latch
     * reports. The old order (window live from configure, buffer created 0.35 s before
     * t0) let a still-open window start the DMA at once, under the next edge's label. */
    uint32_t arm_pos = 0;
    if (armed) {
        double deadline = 0.0;
        if (req->have_t0) {
            double target = edge_s - 1.0 + window_end_s + 0.002;
            if (target < edge_s - ARM_LEAD_S) target = edge_s - ARM_LEAD_S;
            double wait = target - realtime_s();
            if (wait > 0.0) {
                struct timespec ts;
                ts.tv_sec = (time_t)wait;
                ts.tv_nsec = (long)((wait - (double)ts.tv_sec) * 1e9);
                nanosleep(&ts, NULL);
            }
            deadline = edge_s - 0.002;
        } else if (pps_ts_live(&pps, 1.5)) {
            deadline = realtime_s() + 1.0;   /* the gap before the next PPS */
        }
        int d = deadline > 0.0
              ? pps_ts_drive_in_gap((uint32_t)frame_len, (uint32_t)off_raw,
                                    (uint32_t)(nominal_cnt * 0.001), deadline, &arm_pos)
              : -4;
        if (d != 0) {
            iio_device_attr_write(rx, "sync_start_enable", "disarm");
            iio_buffer_destroy(buf);
            restore_rx_mode(frame_len, req->rate_hz);
            pps_ts_close(&pps);
            iio_context_destroy(ctx);
            char m[200];
            if (d == -4)
                snprintf(m, sizeof m, "PPS stopped while preparing TDD capture");
            else if (d == -1)
                snprintf(m, sizeof m, "window still open at the arm deadline (buffer "
                         "allocation took %.0f ms) -- send t0_gps further ahead", alloc_ms);
            else if (d == -2)
                snprintf(m, sizeof m, "arm raced the PPS edge");
            else
                snprintf(m, sizeof m, "pps_counter not mappable (/dev/mem)");
            return fail(out, m);
        }
    }

    /* Anchor read just before refill (== sample[0] for the free-running path). */
    pps_anchor_t anchor; memset(&anchor, 0, sizeof anchor);
    if (have_pps) pps_ts_anchor(&pps, &anchor);
    else {
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
        anchor.gps_ns = (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
        anchor.cnt_hz = (uint32_t)nominal_cnt; anchor.present = false;
    }

    ssize_t nbytes = iio_buffer_refill(buf);
    if (nbytes < 0) {
        iio_buffer_destroy(buf);
        if (armed) { iio_device_attr_write(rx, "sync_start_enable", "disarm");
                     restore_rx_mode(frame_len, req->rate_hz); }
        pps_ts_close(&pps);
        iio_context_destroy(ctx);
        return fail(out, "iio_buffer_refill failed (window missed / DMA error)");
    }

    void  *start = iio_buffer_start(buf);
    size_t bytes = (size_t)((char *)iio_buffer_end(buf) - (char *)start);
    size_t nsamp = bytes / 4;
    double fs = (double)req->rate_hz;
    uint64_t block_ns = (uint64_t)((double)nsamp / fs * 1e9 + 0.5);

    /* TDD-sync timestamp. Preferred: the firmware DMA-start LATCH captured the cnt_clk
     * count of sample[0] in hardware on the channel1 rising edge -> SAMPLE-EXACT, no
     * host read race. Else snap the software anchor to the GPS frame grid. (From
     * iq_capture.c; the non-tdd path keeps the pre-refill anchor as sample[0].) */
    /* Latch-path debug taps, surfaced in the meta (additive fields; consumers ignore
     * unknown keys). latch_off_signed = (int32)(LATCH_COUNT - PPS_COUNT@read): negative
     * means the latch edge predates the newest PPS -- the uint32 sub-second math then
     * wraps to ~frac(2^32/cnt_hz) (the observed +0.497 s / +0.748 s anchor slips). */
    uint32_t dbg_lc = 0, dbg_lseq = 0, dbg_ppsc = 0;
    uint32_t dbg_lseq_prev = lseq_prev;
    int32_t  dbg_latch_off = 0;
    uint64_t dbg_lgps = 0;
    /* Self-check of the gated start, in raw counter ticks (no PPS needed): when the
     * block finished minus its duration is when the DMA really started, and it must not
     * precede the latched edge. A DMA that started inside an already-open window has no
     * edge of its own -- the latch then reports a LATER window and the check goes
     * negative, or nothing is latched at all. Either way the label is wrong: flagged
     * degraded below. LATCH_SEQ reads the ID 0x50505343 on images without the latch. */
    double start_check_ms = 0.0;
    int no_start_edge = 0;
    if (armed && have_pps) {
        uint32_t lc = 0, lseq = 0; uint64_t lgps = 0;
        pps_ts_latch(&pps, &lc, &lseq, &lgps);
        dbg_lc = lc; dbg_lseq = lseq; dbg_lgps = lgps;
        pps_anchor_t now_a; pps_ts_anchor(&pps, &now_a);
        double cnt_chk = pps_ts_cnt_used(&pps, now_a.cnt_hz);
        if (lseq != lseq_prev)
            start_check_ms = ((double)(uint32_t)(now_a.live_count - lc) / cnt_chk
                              - (double)nsamp / fs) * 1e3;
        else if (lseq != 0x50505343u)
            no_start_edge = 1;
        if (lseq != lseq_prev && lgps != 0) {              /* latch fired for this capture */
            dbg_ppsc = now_a.pps_count;
            dbg_latch_off = (int32_t)(lc - now_a.pps_count);
            anchor = now_a;
            anchor.gps_ns = lgps;                          /* hardware, sample-exact */
            anchor.live_count = lc;
            method = "tdd_pps_latch";
        } else {                                           /* snap to the frame grid */
            dbg_ppsc = now_a.pps_count;
            dbg_latch_off = (int32_t)(lc - now_a.pps_count);
            double cnt = pps_ts_cnt_used(&pps, now_a.cnt_hz);
            uint64_t last_pps_ns = now_a.gps_ns -
                (uint64_t)((double)(now_a.live_count - now_a.pps_count) / cnt * 1e9 + 0.5);
            double frame_ns  = (double)frame_len / (fs * lclk_multiple) * 1e9;
            double offset_ns = (double)req->offset_samples / fs * 1e9;
            double start_approx_ns = (double)now_a.gps_ns - (double)block_ns - offset_ns;
            long long kf = (long long)((start_approx_ns - (double)last_pps_ns) / frame_ns + 0.5);
            if (kf < 0) kf = 0;
            anchor = now_a;
            anchor.gps_ns = last_pps_ns + (uint64_t)((double)kf * frame_ns + 0.5)
                            + (uint64_t)(offset_ns + 0.5);
            method = "tdd_pps_window";
        }
    }

    /* --- Level 1: take the INTEGER second from the agreed shared schedule (t0_gps),
     * not the local OS clock. chrony can lock the wrong integer second -- gpsd pins an
     * NMEA epoch to the wrong PPS pulse at 9600 baud, so the clock is phase-perfect but
     * a whole second off (stable for the lock session). The hardware sub-second
     * (anchor.gps_ns % 1e9, from the PPS counter) is unambiguous; only the integer
     * second is fragile. In tdd_sync the capture gates on the first PPS at/after the arm
     * point (t0 - ARM_LEAD_S), so sample 0's true second is ceil(t0 - ARM_LEAD_S) -- for
     * a well-formed integer t0 (a real PPS edge) that is just t0, but it stays correct if
     * t0 carries a fractional part. Re-base to that + the HW sub-second. If the OS clock
     * disagrees by >=1 s, log it and flag the capture degraded -- the consumer can drop it
     * (a skew also means the arm may have gated the wrong PHYSICAL edge, which relabeling
     * cannot fix; that is what the Level-2 gpsd/chrony hardening prevents). */
    int coarse_skew_s = 0;
    const char *second_src = "os_clock";
    if (req->tdd_sync && req->have_t0) {
        const uint64_t NS = 1000000000ULL;
        uint64_t sub_ns  = anchor.gps_ns % NS;             /* HW phase within the second */
        long long os_sec = (long long)(anchor.gps_ns / NS);
        /* PPS-edge boundary fold. A capture window opening AT the PPS edge (offset 0)
         * can latch its DMA-start count one cnt_clk BEFORE the PPS counter re-latches
         * (a +-1-count race, ~50% of boots) -> the signed latch math correctly labels
         * the edge (N-1).999999900 -- 100 ns early, NOT a second late. Folding the
         * near-wrap fraction into the next second keeps the trusted-second rebase and
         * the coarse-skew check on second N with a ~-100 ns sub-second, instead of
         * stamping t0 + 0.9999999 s (observed as a spurious "1000 ms slip" label and
         * a false coarse-skew degraded flag). Real window offsets are <<0.5 s, so the
         * NS/2 threshold cannot fold a legitimate fraction. */
        long long sub_signed = (long long)sub_ns;
        if (sub_ns > NS / 2) { sub_signed -= (long long)NS; os_sec += 1; }
        double gate = req->t0_gps - ARM_LEAD_S;            /* arm point; gate = next PPS >= this */
        long long t0_sec = (long long)gate;                /* floor (gate is positive) ... */
        if ((double)t0_sec < gate) t0_sec += 1;            /* ... -> ceil = the gated PPS second */
        coarse_skew_s = (int)(os_sec - t0_sec);
        anchor.gps_ns = (uint64_t)(t0_sec * (long long)NS + sub_signed); /* trusted second + HW sub-second */
        second_src = "t0_gps";
        if (coarse_skew_s != 0)
            fprintf(stderr, "pluto_ctld: coarse-second skew %+d s (OS %lld vs gated t0 %lld) -- "
                    "anchored to schedule, flagged degraded\n", coarse_skew_s, os_sec, t0_sec);
    }
    int early_start = armed && (start_check_ms < -1.0 || no_start_edge);
    int degraded = (!anchor.present) || (coarse_skew_s != 0) || early_start;
    if (early_start)
        fprintf(stderr, "pluto_ctld: DMA started before the labeled edge (%s) -- "
                "flagged degraded\n", no_start_edge ? "no edge latched" : "block ended early");

    /* --- build the SigMF metadata (in memory). core:frequency = read-back LO. */
    char dt[64]; iso8601_ns(anchor.gps_ns, dt, sizeof dt);
    double xo_ppm = ((double)anchor.cnt_hz - nominal_cnt) / nominal_cnt * 1e6;
    if (anchor.cnt_hz == 0) xo_ppm = 0.0;
    const char *node = (req->node_id && req->node_id[0]) ? req->node_id : "pluto";
    char posbuf[160] = "";
    if (req->have_pos)
        snprintf(posbuf, sizeof posbuf,
                 "    \"gpsanchor:antenna_position\": [%.8f, %.8f, %.3f],\n",
                 req->lat, req->lon, req->alt);

    size_t metacap = 3584;
    char *meta = (char *)malloc(metacap);
    if (!meta) { rc = fail(out, "oom (meta)"); goto cleanup; }
    snprintf(meta, metacap,
      "{\n"
      "  \"global\": {\n"
      "    \"core:datatype\": \"ci16_le\",\n"
      "    \"core:sample_rate\": %lld.0,\n"
      "    \"core:version\": \"1.0.0\",\n"
      "    \"core:num_channels\": 1,\n"
      "    \"core:hw\": \"PlutoSDR/AD936x\",\n"
      "    \"gpsanchor:node_id\": \"%s\",\n"
      "%s"
      "    \"timing:health\": {\n"
      "      \"pps_present\": %s,\n"
      "      \"xo_ppm\": %.4f,\n"
      "      \"latch_rms_ns\": 16.0,\n"
      "      \"degraded\": %s\n"
      "    }\n"
      "  },\n"
      "  \"captures\": [\n"
      "    {\n"
      "      \"core:sample_start\": 0,\n"
      "      \"core:frequency\": %lld.0,\n"
      "      \"core:datetime\": \"%s\",\n"
      "      \"gpsanchor:gps_ns0\": %llu,\n"
      "      \"gpsanchor:cnt_clk_hz\": %u,\n"
      "      \"gpsanchor:method\": \"%s\",\n"
      "      \"gpsanchor:sample_index0\": %u,\n"
      "      \"gpsanchor:pps_count\": %u,\n"
      "      \"gpsanchor:pps_seq\": %u,\n"
      "      \"gpsanchor:second_source\": \"%s\",\n"
      "      \"gpsanchor:coarse_skew_s\": %d,\n"
      "      \"gpsanchor:latch_count\": %u,\n"
      "      \"gpsanchor:latch_seq\": %u,\n"
      "      \"gpsanchor:latch_seq_prev\": %u,\n"
      "      \"gpsanchor:latch_gps_ns\": %llu,\n"
      "      \"gpsanchor:pps_count_at_read\": %u,\n"
      "      \"gpsanchor:latch_off_signed\": %ld,\n"
      "      \"ctl:alloc_ms\": %.1f,\n"
      "      \"ctl:max_block_size\": %lld,\n"
      "      \"ctl:arm_frame_pos\": %u,\n"
      "      \"ctl:start_check_ms\": %.3f,\n"
      "      \"ctl:cnt_clk_settled\": %s,\n"
      "      \"ctl:start_edge_latched\": %s\n"
      "    }\n"
      "  ],\n"
      "  \"annotations\": []\n"
      "}\n",
      req->rate_hz, node, posbuf,
      anchor.present ? "true" : "false", xo_ppm, degraded ? "true" : "false",
      actual_lo, dt, (unsigned long long)anchor.gps_ns, anchor.cnt_hz,
      method, anchor.live_count, anchor.pps_count, anchor.pps_seq,
      second_src, coarse_skew_s,
      dbg_lc, dbg_lseq, dbg_lseq_prev, (unsigned long long)dbg_lgps,
      dbg_ppsc, (long)dbg_latch_off, alloc_ms, block_cap, arm_pos, start_check_ms,
      pps_ts_cnt_used(&pps, anchor.cnt_hz) == (double)anchor.cnt_hz ? "true" : "false",
      no_start_edge ? "false" : "true");

    /* Zero-copy: hand out the IQ where the DMA put it. The block stays ours until
     * capture_release() destroys the buffer (it is the only block, so restoring
     * free-running RX below leaves the DMA nothing to fill). */
    struct capture_handle *h = (struct capture_handle *)malloc(sizeof *h);
    if (!h) { free(meta); rc = fail(out, "oom (handle)"); goto cleanup; }
    h->buf = buf; h->ctx = ctx;
    out->meta_json = meta;
    out->iq = (uint8_t *)start;
    out->iq_len = bytes;
    out->priv = h;
    rc = 0;

cleanup:
    if (armed) {
        iio_device_attr_write(rx, "sync_start_enable", "disarm");
        restore_rx_mode(frame_len, req->rate_hz);  /* full-open window -> normal RX, no reboot */
    }
    if (have_pps) pps_ts_close(&pps);
    if (rc != 0) {
        iio_buffer_destroy(buf);
        iio_context_destroy(ctx);
    }
    return rc;
}
