/*
 * iq_stream.c - PROTOTYPE continuous, GPS-anchored IQ stream: Pluto+ RX0 -> a host ring.
 *
 * Sample 0 lands on a PPS edge and is latched to the counter tick (the held-arm start of
 * capture_core); from then on the DMA free-runs through N kernel blocks and each block
 * goes out zero-copy as two ZMQ frames: a JSON header and the block's ci16_le IQ.
 *
 *   header: {"seq":k, "i0":first sample index, "n":samples, "fs":Hz, "fc":Hz,
 *            "t0_ns":GPS ns of sample 0, "lag":samples, "ovf":bool,
 *            "pps":[pps_seq, sample index of that PPS edge (fractional), GPS second] or null}
 *
 * Any sample's GPS time follows from the PPS markers (one per second): the stream counts
 * samples, the markers say where each GPS second fell in that count, so a drifting sample
 * clock costs nothing. "lag" is how far the delivered stream trails the hardware
 * (counter-elapsed samples minus delivered samples): more than the queue depth means the
 * DMA ran out of blocks and samples were lost, as does "ovf" (the ADC core's sticky DMA
 * overflow). While streaming it holds /tmp/pluto_ctld.capturing, so xo_correct.sh does
 * not step the clocks under the DMA.
 *
 * Usage: iq_stream --connect tcp://HOST:5563 [--rate HZ] [--freq HZ] [--gain DB]
 *                  [--block-ms MS] [--blocks N] [--seconds S]
 * The receiver binds a PULL socket first. One radio owner: stop DSN (pluto_ctld idle).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <iio.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <zmq.h>

#include "capture_core.h"
#include "pps_timestamp.h"

#define R_LIVE      (0x0C / 4)
#define R_PPS_COUNT (0x10 / 4)
#define R_PPS_DELTA (0x14 / 4)
#define R_PPS_SEQ   (0x18 / 4)
#define DMA_STATUS  0x80000088u    /* ADC core register (DEBUGFS_DRA_PCORE_REG_MAGIC) */
#define DMA_OVF     0x4u
#define LOCK_PATH   "/tmp/pluto_ctld.capturing"
#define GATE_FRAME  2000000000LL   /* axi_tdd frame while streaming: one LOW clock per frame */

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int s) { (void)s; g_stop = 1; }

static double realtime_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void lock_touch(void) {
    FILE *f = fopen(LOCK_PATH, "w");
    if (f) { fprintf(f, "%d\n", (int)getpid()); fclose(f); }
}

/* zmq frees a zero-copy frame: wake the loop, which may then re-queue the block. */
static void block_sent(void *data, void *hint) {
    (void)data;
    char c = 1;
    ssize_t w = write((int)(intptr_t)hint, &c, 1);
    (void)w;
}

static int die(const char *m) { fprintf(stderr, "iq_stream: %s\n", m); return 1; }

int main(int argc, char **argv) {
    long long rate = 5000000, freq = 94700000;
    double gain = NAN, block_ms = 100.0, seconds = 0.0;
    int nblocks = 8;
    const char *connect = NULL;
    for (int i = 1; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--connect")) connect = argv[i + 1];
        else if (!strcmp(argv[i], "--rate")) rate = atoll(argv[i + 1]);
        else if (!strcmp(argv[i], "--freq")) freq = atoll(argv[i + 1]);
        else if (!strcmp(argv[i], "--gain")) gain = atof(argv[i + 1]);
        else if (!strcmp(argv[i], "--block-ms")) block_ms = atof(argv[i + 1]);
        else if (!strcmp(argv[i], "--blocks")) nblocks = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--seconds")) seconds = atof(argv[i + 1]);
        else return die("unknown option");
    }
    if (!connect || rate <= 0 || nblocks < 1 || block_ms <= 0 || block_ms > 300)
        return die("need --connect; --blocks >= 1; 0 < --block-ms <= 300");
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    struct iio_context *ctx = iio_create_local_context();
    if (!ctx) return die("no local iio context");
    struct iio_device *phy = iio_context_find_device(ctx, "ad9361-phy");
    struct iio_device *rx = iio_context_find_device(ctx, "cf-ad9361-lpc");
    struct iio_channel *p_rx = phy ? iio_device_find_channel(phy, "voltage0", false) : NULL;
    struct iio_channel *p_lo = phy ? iio_device_find_channel(phy, "altvoltage0", true) : NULL;
    struct iio_channel *i0 = rx ? iio_device_find_channel(rx, "voltage0", false) : NULL;
    struct iio_channel *q0 = rx ? iio_device_find_channel(rx, "voltage1", false) : NULL;
    if (!p_rx || !p_lo || !i0 || !q0) return die("ad9361 devices/channels not found");

    pps_ts_t pps;
    if (pps_ts_init(&pps, 0.0) != 0) return die("pps_counter not mappable");
    if (!pps_ts_live(&pps, 1.5)) return die("no live PPS: the stream's sample 0 needs one");
    /* counter clock per sample (l_clk multiple), from PPS_DELTA at the current rate */
    long long cur = 0;
    iio_channel_attr_read_longlong(p_rx, "sampling_frequency", &cur);
    int mult = 2;
    uint32_t cnt_hz = pps.regs[R_PPS_DELTA];
    if (cnt_hz > 0 && cur > 0) {
        long long m = ((long long)cnt_hz + cur / 2) / cur;
        if (m >= 1 && m <= 4) mult = (int)m;
    }

    /* tune once: a rate or LO write disturbs the sample clock for that second */
    iio_channel_attr_write_longlong(p_rx, "sampling_frequency", rate);
    iio_channel_attr_write_longlong(p_rx, "rf_bandwidth", rate);
    if (isnan(gain)) {
        iio_channel_attr_write(p_rx, "gain_control_mode", "slow_attack");
    } else {
        iio_channel_attr_write(p_rx, "gain_control_mode", "manual");
        iio_channel_attr_write_double(p_rx, "hardwaregain", gain);
    }
    iio_channel_attr_write_longlong(p_lo, "frequency", freq);
    long long fs = rate, fc = freq;
    iio_channel_attr_read_longlong(p_rx, "sampling_frequency", &fs);
    pps.nominal_cnt_hz = (double)mult * (double)fs;   /* the latch's plausibility check */
    iio_channel_attr_read_longlong(p_lo, "frequency", &fc);
    iio_channel_enable(i0);
    iio_channel_enable(q0);
    lock_touch();

    void *zctx = zmq_ctx_new();
    void *push = zmq_socket(zctx, ZMQ_PUSH);
    int linger = 0;
    zmq_setsockopt(push, ZMQ_LINGER, &linger, sizeof linger);
    if (zmq_connect(push, connect) != 0) return die("zmq connect failed");
    usleep(300000);                                  /* let the connection come up */

    /* Arm: window [0, 0.5 s) of each PPS frame, output held until the blocks are queued */
    long long frame_len = (long long)mult * rate;
    long long win = frame_len / 2;
    size_t n_blk = (size_t)((double)rate * block_ms / 1000.0) & ~(size_t)1023;
    if (capture_gate_hold(ctx) != 0) return die("axi_tdd not found");
    if (pps_ts_config_frame((uint32_t)frame_len, 0, (uint32_t)win) != 0)
        return die("pps_counter frame config failed");
    uint32_t lseq_prev = 0;
    pps_ts_latch(&pps, NULL, &lseq_prev, NULL);
    /* arm the RX core's sync start around buffer creation, as capture_core does: without
     * it the DMA does not wait for the gate (a first block arrives with no edge latched) */
    const char *am = getenv("IQ_ARM");           /* prototype: 0 none, 1 before, 2 after, 3 both */
    int arm_mode = am ? atoi(am) : 3;
    if ((arm_mode & 1) && iio_device_attr_write(rx, "sync_start_enable", "arm") < 0) {
        capture_gate_open(frame_len, rate);
        return die("sync_start_enable not settable");
    }
    iio_device_set_kernel_buffers_count(rx, (unsigned int)nblocks);
    struct iio_buffer *buf = iio_device_create_buffer(rx, n_blk, false);
    if (!buf) { capture_gate_open(frame_len, rate); return die("create_buffer failed"); }
    if (arm_mode & 2) iio_device_attr_write(rx, "sync_start_enable", "arm");
    iio_context_set_timeout(ctx, 3000);
    uint32_t pos = 0;
    if (!pps_ts_live(&pps, 1.5) ||
        pps_ts_drive_in_gap((uint32_t)frame_len, (uint32_t)win, (uint32_t)(mult * rate / 1000),
                            realtime_s() + 1.0, &pos) != 0) {
        iio_buffer_destroy(buf);
        capture_gate_open(frame_len, rate);
        return die("could not release the window before the PPS edge");
    }

    double t_rel = realtime_s();
    uint32_t lc = 0, lseq = 0, live_prev = 0, seq_prev = 0, start_seq = 0;
    uint64_t lgps = 0, cnt64 = 0, t0_ns = 0, sent_n = 0;
    double t_lock = realtime_s(), t_start = 0.0, max_lag = 0.0;
    long long start_sec = 0;
    unsigned long long k = 0, lost_blocks = 0;
    int fd[2];
    if (pipe(fd) != 0) return die("pipe");

    while (!g_stop) {
        ssize_t nb = iio_buffer_refill(buf);
        if (nb < 0) { fprintf(stderr, "iq_stream: refill failed (%zd) at block %llu\n", nb, k); break; }
        uint32_t live = pps.regs[R_LIVE];
        if (k == 0) {
            /* sample 0 is the latched edge; then hand the gate to axi_tdd, open for good,
             * before the 0.5 s window closes, and drop the window */
            pps_ts_latch(&pps, &lc, &lseq, &lgps);
            if (lseq == lseq_prev || lgps == 0) {
                fprintf(stderr, "iq_stream: no start edge latched (latch seq %u -> %u, count %u, "
                        "gps_ns %llu; released at frame pos %u, block 0 back %.3f s later, "
                        "frame pos now %u, PPS seq %u)\n", lseq_prev, lseq, lc,
                        (unsigned long long)lgps, pos, realtime_s() - t_rel,
                        pps.regs[0x34 / 4], pps.regs[R_PPS_SEQ]);
                break;
            }
            capture_gate_open(GATE_FRAME, rate);
            t0_ns = lgps;
            start_sec = (long long)((lgps + 500000000ULL) / 1000000000ULL);
            start_seq = pps.regs[R_PPS_SEQ];
            seq_prev = start_seq;
            live_prev = lc;
            t_start = realtime_s();
            fprintf(stderr, "iq_stream: started at GPS %lld (t0_ns %llu), %.3f MS/s, LO %.3f MHz, "
                    "%zu-sample blocks x %d, mult %d\n", start_sec, (unsigned long long)t0_ns,
                    fs / 1e6, fc / 1e6, n_blk, nblocks, mult);
        }
        cnt64 += (uint32_t)(live - live_prev);
        live_prev = live;
        double elapsed = (double)cnt64 / mult;                 /* samples since sample 0 */
        double lag = elapsed - (double)((k + 1) * n_blk);
        if (lag > max_lag) max_lag = lag;
        if (lag > (double)nblocks * n_blk) lost_blocks++;
        uint32_t dma = 0;
        int ovf = iio_device_reg_read(rx, DMA_STATUS, &dma) == 0 && (dma & DMA_OVF);
        if (ovf) iio_device_reg_write(rx, DMA_STATUS, DMA_OVF);    /* sticky: clear */

        char pbuf[96] = "null";
        uint32_t seq = pps.regs[R_PPS_SEQ];
        if (seq != seq_prev) {
            uint32_t ppsc = pps.regs[R_PPS_COUNT];
            uint64_t pps64 = cnt64 - (uint32_t)(live - ppsc);       /* counts since sample 0 */
            snprintf(pbuf, sizeof pbuf, "[%u, %.3f, %lld]", seq, (double)pps64 / mult,
                     start_sec + (long long)(uint32_t)(seq - start_seq));
            seq_prev = seq;
        }
        char hdr[384];
        int hl = snprintf(hdr, sizeof hdr,
            "{\"seq\":%llu,\"i0\":%llu,\"n\":%zu,\"fs\":%lld,\"fc\":%lld,\"t0_ns\":%llu,"
            "\"lag\":%.0f,\"ovf\":%s,\"pps\":%s}", k, (unsigned long long)(k * n_blk),
            (size_t)nb / 4, fs, fc, (unsigned long long)t0_ns, lag, ovf ? "true" : "false", pbuf);
        zmq_send(push, hdr, (size_t)hl, ZMQ_SNDMORE);
        zmq_msg_t m;
        zmq_msg_init_data(&m, iio_buffer_start(buf), (size_t)nb, block_sent, (void *)(intptr_t)fd[1]);
        if (zmq_msg_send(&m, push, 0) < 0) zmq_msg_close(&m);
        struct pollfd p = { fd[0], POLLIN, 0 };
        if (poll(&p, 1, 5000) != 1) { fprintf(stderr, "iq_stream: send stalled 5 s\n"); break; }
        char c;
        ssize_t r = read(fd[0], &c, 1);
        (void)r;
        sent_n += (uint64_t)nb / 4;
        k++;
        if (realtime_s() - t_lock > 30.0) { lock_touch(); t_lock = realtime_s(); }
        if (seconds > 0 && (double)sent_n / fs >= seconds) break;
    }

    double dt = k > 0 ? realtime_s() - t_start : 0.0;
    fprintf(stderr, "iq_stream: %llu blocks, %.1f s of IQ in %.1f s (%.1f MB/s), max lag %.0f "
            "samples (queue %zu), %llu blocks past the queue\n", k, (double)sent_n / fs, dt,
            dt > 0 ? sent_n * 4.0 / dt / 1e6 : 0.0, max_lag, (size_t)nblocks * n_blk, lost_blocks);
    iio_device_attr_write(rx, "sync_start_enable", "disarm");
    iio_buffer_destroy(buf);
    capture_gate_open(frame_len, rate);              /* free-running RX, synced */
    unlink(LOCK_PATH);
    zmq_close(push);
    zmq_ctx_term(zctx);
    pps_ts_close(&pps);
    iio_context_destroy(ctx);
    return 0;
}
