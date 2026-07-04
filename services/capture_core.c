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

#define LCLK_MAX_HZ 122880000.0  /* validated LibreSDR l_clk ceiling */
#define TDD_V2_PATH "/sys/bus/platform/devices/7c440000.tdd"

static struct iio_device *g_tdd = NULL;
static int g_tdd_v2 = 0;

static int sysfs_write(const char *name, long long value) {
    char path[256];
    snprintf(path, sizeof path, "%s/%s", TDD_V2_PATH, name);
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    int rc = fprintf(f, "%lld\n", value) < 0 ? -2 : 0;
    if (fclose(f) != 0 && rc == 0) rc = -3;
    return rc;
}

/* GPS-sequenced capture via the ADI axi_tdd core (no firmware change): the base BD
 * wires axi_tdd_0/tdd_channel_1 -> RX-DMA/sync (LEVEL: DMA transfers while HIGH) and
 * pps_tick -> axi_tdd/sync_in (GPS-anchors the frame). Program channel1 as a window
 * [on_raw, off_raw) per frame. sync_external selects the GPS input and sync_reset
 * makes every GPS edge reset the running counter (external sync alone only starts
 * an armed core).
 * An armed RX buffer then starts when the window opens = a GPS-deterministic edge.
 * TDD raw counts are in sample-clock (fs) units. (Verbatim from iq_capture.c.) */
static int configure_tdd(struct iio_context *ctx, long long frame_raw,
                         long long on_raw, long long off_raw) {
    g_tdd = iio_context_find_device(ctx, "iio-axi-tdd-0");
    g_tdd_v2 = 0;
    if (!g_tdd && access(TDD_V2_PATH "/enable", F_OK) == 0) {
        g_tdd_v2 = 1;
        if (frame_raw < 2) return -1;
        if (sysfs_write("enable", 0) ||
            sysfs_write("frame_length_raw", frame_raw + (frame_raw / 10)) ||
            sysfs_write("out_channel1_on_raw", on_raw) ||
            sysfs_write("out_channel1_off_raw", off_raw) ||
            sysfs_write("out_channel1_polarity", 0) ||
            sysfs_write("out_channel1_enable", 1) ||
            sysfs_write("sync_external", 1) ||
            sysfs_write("sync_reset", 1) ||
            sysfs_write("enable", 1))
            return -2;

        return 0;
    }
    if (!g_tdd) return -3;
    struct iio_channel *ch1 = iio_device_find_channel(g_tdd, "channel1", true);
    if (!ch1) return -4;
    char b[32];
    iio_device_attr_write(g_tdd, "enable", "0");
    long long guarded_frame_raw = frame_raw + (frame_raw / 10);
    snprintf(b, sizeof b, "%lld", guarded_frame_raw);
    iio_device_attr_write(g_tdd, "frame_length_raw", b);
    snprintf(b, sizeof b, "%lld", on_raw);     iio_channel_attr_write(ch1, "on_raw", b);
    snprintf(b, sizeof b, "%lld", off_raw);    iio_channel_attr_write(ch1, "off_raw", b);
    iio_channel_attr_write(ch1, "polarity", "0");
    iio_channel_attr_write(ch1, "enable", "1");
    iio_device_attr_write(g_tdd, "sync_external", "1");
    iio_device_attr_write(g_tdd, "sync_reset", "1");      /* re-anchor every PPS */
    iio_device_attr_write(g_tdd, "enable", "1");
    return 0;
}

/* Restore normal RX WITHOUT a reboot: do NOT disable the core (that latches channel1
 * LOW and starves the DMA). Instead set channel1 to a full-open window (always HIGH)
 * so the RX DMA captures freely again. Validated live. (Verbatim from iq_capture.c.) */
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
        return;
    }
    if (!g_tdd) return;
    struct iio_channel *ch1 = iio_device_find_channel(g_tdd, "channel1", true);
    char b[32];
    if (ch1) {
        iio_channel_attr_write(ch1, "on_raw", "0");
        snprintf(b, sizeof b, "%lld", frame_len > 0 ? frame_len : rate);
        iio_channel_attr_write(ch1, "off_raw", b);   /* off = frame_length -> always high */
        iio_channel_attr_write(ch1, "enable", "1");
    }
    /* leave the core ENABLED (disabling it is what breaks RX) */
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

int capture_run(const capture_req_t *req, capture_result_t *out) {
    out->meta_json = NULL; out->iq = NULL; out->iq_len = 0; out->err[0] = '\0';

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

    /* --- §7 channel-mode rate cap. l_clk = n_active_rx * sample_rate; refuse any
     * requested rate whose l_clk would overrun the AD9361 interface (-> DMA wedge).
     * Detect n_active from the live counter (PPS_DELTA) vs the current sysfs rate. */
    pps_ts_t pps;
    int have_pps = (pps_ts_init(&pps, LCLK_MAX_HZ) == 0);
    long long cur_rate = 0;
    iio_channel_attr_read_longlong(p_rx, "sampling_frequency", &cur_rate);
    int lclk_multiple = 2;  /* conservative Pluto+ fallback */
    if (have_pps) {
        uint32_t cnt = pps_ts_cnt_hz(&pps);
        if (cnt > 0 && cur_rate > 0) {
            long long r = ((long long)cnt + cur_rate / 2) / cur_rate;  /* round */
            if (r >= 1 && r <= 4) lclk_multiple = (int)r;
        }
    }
    double max_rate = LCLK_MAX_HZ / (double)lclk_multiple;
    if (max_rate > 61440000.0) max_rate = 61440000.0; /* AD936x sample-rate limit */
    if ((double)req->rate_hz > max_rate) {
        char m[160];
        snprintf(m, sizeof m, "sample_rate_hz %lld exceeds %.0f for l_clk multiple %d",
                 req->rate_hz, max_rate, lclk_multiple);
        if (have_pps) pps_ts_close(&pps);
        iio_context_destroy(ctx);
        return fail(out, m);
    }

    /* Prove liveness once per request by observing a new PPS edge. Reuse the
     * result below so require_gps+tdd_sync does not wait for two edges. */
    int live_pps = 0;
    if (have_pps && (req->require_gps || req->tdd_sync))
        live_pps = pps_ts_live(&pps, 1.5);

    /* --require-gps: refuse un-anchored data when a live PPS is demanded. */
    if (req->require_gps && !live_pps) {
        if (have_pps) pps_ts_close(&pps);
        iio_context_destroy(ctx);
        return fail(out, "not GPS-trusted (pps_present=false)");
    }

    /* nominal cnt_clk for this capture's mode (drives xo_ppm + the anchor fallback). */
    double nominal_cnt = (double)lclk_multiple * (double)req->rate_hz;
    pps.nominal_cnt_hz = nominal_cnt;

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
    int armed = 0;
    uint32_t lseq_prev = 0;

    if (req->tdd_sync) {
        method = "tdd_pps_window";
        /* GUARD: arming the DMA without a window that WILL open wedges it (reboot to
         * clear). Require a live GPS PPS so the sync_external frame actually runs. */
        if (!live_pps) {
            if (have_pps) pps_ts_close(&pps);
            iio_context_destroy(ctx);
            return fail(out, "tdd_sync needs a live GPS PPS (would wedge the DMA)");
        }
        frame_len = lclk_multiple * req->rate_hz;  /* one GPS second in l_clk counts */
        /* channel1 window [on_raw, off_raw): on_raw = offset_samples; off must cover the
         * offset + whole capture + arm-latency margin and stay inside the frame. */
        long long on_raw = req->offset_samples * lclk_multiple;
        off_raw = (req->offset_samples + (long long)req->samples +
                   (long long)(req->samples / 2)) * lclk_multiple;
        long long setup_guard_raw = (long long)(nominal_cnt * 0.020);
        if (req->offset_samples < 0 ||
            off_raw >= frame_len - setup_guard_raw) {
            char m[160];
            snprintf(m, sizeof m, "offset(%lld)+capture(%zu)+margin leaves <20ms before PPS",
                     req->offset_samples, req->samples);
            pps_ts_close(&pps);
            iio_context_destroy(ctx);
            return fail(out, m);
        }
        if (configure_tdd(ctx, frame_len, on_raw, off_raw) != 0) {
            pps_ts_close(&pps);
            iio_context_destroy(ctx);
            return fail(out, "axi_tdd channel1 config failed");
        }
        iio_context_set_timeout(ctx, 4000);   /* a missed window errors, not hangs */

        /* With an agreed future edge, wait before arming. Arming earlier allows
         * buffer creation to consume an intervening PPS instead of t0_gps. */
        if (req->have_t0) {
            struct timespec now;
            clock_gettime(CLOCK_REALTIME, &now);
            double now_s = (double)now.tv_sec + (double)now.tv_nsec / 1e9;
            double wait = req->t0_gps - now_s - 0.35;
            if (wait <= 0.0 || wait >= 60.0) {
                restore_rx_mode(frame_len, req->rate_hz);
                pps_ts_close(&pps);
                iio_context_destroy(ctx);
                return fail(out, "t0_gps must be 0.35 to 60 seconds in the future");
            }
            struct timespec ts;
            ts.tv_sec = (time_t)wait;
            ts.tv_nsec = (long)((wait - (double)ts.tv_sec) * 1e9);
            nanosleep(&ts, NULL);
        } else {
            /* Observe one PPS after configuring so the finite window definitely
             * replaces the normal full-open state. Then let that window close
             * and arm for the following PPS. */
            if (!pps_ts_live(&pps, 1.5)) {
                restore_rx_mode(frame_len, req->rate_hz);
                pps_ts_close(&pps);
                iio_context_destroy(ctx);
                return fail(out, "PPS stopped while preparing TDD capture");
            }
            double settle_s = (double)off_raw / nominal_cnt + 0.010;
            struct timespec ts;
            ts.tv_sec = (time_t)settle_s;
            ts.tv_nsec = (long)((settle_s - (double)ts.tv_sec) * 1e9);
            nanosleep(&ts, NULL);
        }

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

    /* One iio_buffer_refill == ONE DMA block, gap-free internally, bounded by CMA /
     * the 64 MiB DMA-block limit (~16 M samples ~= 0.5 s @ 30.72 MSPS). */
    int rc = 0;
    struct iio_buffer *buf = iio_device_create_buffer(rx, req->samples, false);
    if (!buf) {
        if (armed) { iio_device_attr_write(rx, "sync_start_enable", "disarm");
                     restore_rx_mode(frame_len, req->rate_hz); }
        pps_ts_close(&pps);
        iio_context_destroy(ctx);
        return fail(out, "create_buffer failed (CMA / 64 MiB limit -- fewer samples)");
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
    if (armed && have_pps) {
        uint32_t lc = 0, lseq = 0; uint64_t lgps = 0;
        pps_ts_latch(&pps, &lc, &lseq, &lgps);
        if (lseq != lseq_prev && lgps != 0) {              /* latch fired for this capture */
            pps_anchor_t now_a; pps_ts_anchor(&pps, &now_a);
            anchor = now_a;
            anchor.gps_ns = lgps;                          /* hardware, sample-exact */
            anchor.live_count = lc;
            method = "tdd_pps_latch";
        } else {                                           /* snap to the frame grid */
            pps_anchor_t now_a; pps_ts_anchor(&pps, &now_a);
            double cnt = (double)now_a.cnt_hz;
            if (cnt < nominal_cnt * 0.5 || cnt > nominal_cnt * 1.5) cnt = nominal_cnt;
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

    size_t metacap = 2048;
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
      "      \"gpsanchor:pps_seq\": %u\n"
      "    }\n"
      "  ],\n"
      "  \"annotations\": []\n"
      "}\n",
      req->rate_hz, node, posbuf,
      anchor.present ? "true" : "false", xo_ppm, anchor.present ? "false" : "true",
      actual_lo, dt, (unsigned long long)anchor.gps_ns, anchor.cnt_hz,
      method, anchor.live_count, anchor.pps_count, anchor.pps_seq);

    /* copy the IQ out of the iio buffer (freed below). */
    uint8_t *iqcopy = (uint8_t *)malloc(bytes ? bytes : 1);
    if (!iqcopy) { free(meta); rc = fail(out, "oom (iq)"); goto cleanup; }
    memcpy(iqcopy, start, bytes);

    out->meta_json = meta;
    out->iq = iqcopy;
    out->iq_len = bytes;
    rc = 0;

cleanup:
    if (armed) {
        iio_device_attr_write(rx, "sync_start_enable", "disarm");
        restore_rx_mode(frame_len, req->rate_hz);  /* full-open window -> normal RX, no reboot */
    }
    iio_buffer_destroy(buf);
    if (have_pps) pps_ts_close(&pps);
    iio_context_destroy(ctx);
    return rc;
}
