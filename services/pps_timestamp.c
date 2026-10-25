/*
 * pps_timestamp.c - see pps_timestamp.h. VENDORED from the DSN/sdr-stack
 * device/streamer (validated on hardware: LIVE_COUNT advances at PPS_DELTA, the
 * counter->GPS-time map agrees with the disciplined system clock); the held window
 * output and pps_ts_drive_in_gap() were added here.
 */
#define _POSIX_C_SOURCE 199309L   /* clock_gettime / CLOCK_REALTIME */
#include "pps_timestamp.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

#define REG_STATUS    (0x08 / 4)
#define REG_LIVE      (0x0C / 4)
#define REG_PPS_COUNT (0x10 / 4)
#define REG_PPS_DELTA (0x14 / 4)
#define REG_PPS_SEQ   (0x18 / 4)
#define NS_PER_S      1000000000ULL
#define MAP_SIZE      0x1000

int pps_ts_init(pps_ts_t *p, double nominal_cnt_hz) {
    p->regs = NULL; p->mem_fd = -1; p->nominal_cnt_hz = nominal_cnt_hz; p->cnt_tol = 0.5;
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) return -1;
    void *m = mmap(NULL, MAP_SIZE, PROT_READ, MAP_SHARED, fd, (off_t)PPS_COUNTER_BASE);
    if (m == MAP_FAILED) { close(fd); return -2; }
    p->mem_fd = fd;
    p->regs = (volatile uint32_t *)m;
    return 0;
}

void pps_ts_close(pps_ts_t *p) {
    if (p->regs) { munmap((void *)p->regs, MAP_SIZE); p->regs = NULL; }
    if (p->mem_fd >= 0) { close(p->mem_fd); p->mem_fd = -1; }
}

bool pps_ts_present(const pps_ts_t *p) {
    return p->regs && (p->regs[REG_STATUS] & 0x1);
}

bool pps_ts_live(const pps_ts_t *p, double timeout_seconds) {
    if (!p->regs || timeout_seconds <= 0.0) return false;

    uint32_t seq = p->regs[REG_PPS_SEQ];
    struct timespec start, now, pause = { 0, 10000000L }; /* poll at 100 Hz */
    clock_gettime(CLOCK_MONOTONIC, &start);
    do {
        if (p->regs[REG_PPS_SEQ] != seq) return true;
        nanosleep(&pause, NULL);
        clock_gettime(CLOCK_MONOTONIC, &now);
    } while ((double)(now.tv_sec - start.tv_sec) +
             (double)(now.tv_nsec - start.tv_nsec) / 1e9 < timeout_seconds);
    return false;
}

uint32_t pps_ts_cnt_hz(const pps_ts_t *p) {
    return p->regs ? p->regs[REG_PPS_DELTA] : 0;
}

double pps_ts_cnt_used(const pps_ts_t *p, uint32_t pps_delta) {
    double cnt = (double)pps_delta;
    double tol = p->nominal_cnt_hz * p->cnt_tol;
    if (cnt < p->nominal_cnt_hz - tol || cnt > p->nominal_cnt_hz + tol)
        cnt = p->nominal_cnt_hz;              /* PPS_DELTA not (yet) valid */
    return cnt;
}

/* Most recent integer second of the PPS-disciplined system clock = GPS time of
 * the last PPS edge (PPS fires on the GPS second). */
static uint64_t last_pps_gps_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * NS_PER_S;   /* drop the sub-second part */
}

uint64_t pps_ts_now_ns(const pps_ts_t *p) {
    if (!p->regs) return 0;
    /* Read PPS_COUNT before and after LIVE so a PPS edge mid-read is detected. */
    uint32_t pps_count = p->regs[REG_PPS_COUNT];
    uint32_t live      = p->regs[REG_LIVE];
    uint64_t base_ns   = last_pps_gps_ns();
    double   cnt_hz    = pps_ts_cnt_used(p, p->regs[REG_PPS_DELTA]);
    /* (live - pps_count) is modulo-2^32; the cast handles wrap within one second. */
    uint32_t since = live - pps_count;
    return base_ns + (uint64_t)((double)since / cnt_hz * 1e9 + 0.5);
}

uint64_t pps_ts_buffer_start_ns(const pps_ts_t *p, uint64_t n_samples, double fs_hz) {
    uint64_t now = pps_ts_now_ns(p);
    uint64_t age_ns = (uint64_t)((double)n_samples / fs_hz * 1e9 + 0.5);
    return (now > age_ns) ? now - age_ns : 0;
}

#define REG_TDD_CTRL  (0x1C / 4)   /* bit0 enable, bit1 pps_sync_en */
#define REG_FRAME_LEN (0x20 / 4)
#define REG_RX_START  (0x24 / 4)
#define REG_RX_STOP   (0x28 / 4)
#define REG_FRAME_POS (0x34 / 4)
#define TDD_CTRL_HELD  0x3         /* enable|pps_sync_en: frame runs, output low */
#define TDD_CTRL_DRIVE 0x7         /* + drive_pins: tdd_enable outputs the window */

/* RW-map the pps_counter just long enough to write the frame regs. */
static int frame_write(uint32_t ctrl, uint32_t flen, uint32_t rxa, uint32_t rxo) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) return -1;
    volatile uint32_t *r = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, (off_t)PPS_COUNTER_BASE);
    if (r == MAP_FAILED) { close(fd); return -2; }
    r[REG_TDD_CTRL]  = 0;          /* disable while reprogramming */
    r[REG_FRAME_LEN] = flen;
    r[REG_RX_START]  = rxa;
    r[REG_RX_STOP]   = rxo;
    r[REG_TDD_CTRL]  = ctrl;       /* arm last */
    munmap((void *)r, MAP_SIZE);
    close(fd);
    return 0;
}

int pps_ts_config_frame(uint32_t frame_len, uint32_t rx_start, uint32_t rx_stop) {
    /* enable|pps_sync_en: the frame resets on each PPS -> GPS-locked. drive_pins (bit2)
     * stays clear, so tdd_enable -- ORed into the RX-DMA sync -- holds low until
     * pps_ts_drive_in_gap() sets it. */
    return frame_write(TDD_CTRL_HELD, frame_len, rx_start, rx_stop);
}

static double realtime_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int pps_ts_drive_in_gap(uint32_t frame_len, uint32_t rx_stop, uint32_t guard,
                        double deadline_s, uint32_t *pos) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) return -3;
    volatile uint32_t *r = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, (off_t)PPS_COUNTER_BASE);
    if (r == MAP_FAILED) { close(fd); return -3; }
    struct timespec pause = { 0, 200000L };   /* 0.2 ms; the gap is >= 20 ms */
    int rc = -1;
    while (realtime_now() < deadline_s) {
        uint32_t p0 = r[REG_FRAME_POS];
        if (p0 >= rx_stop + guard && p0 + guard < frame_len) {
            r[REG_TDD_CTRL] = TDD_CTRL_DRIVE;
            uint32_t p1 = r[REG_FRAME_POS];
            if (pos) *pos = p0;
            rc = (p1 >= p0) ? 0 : -2;
            break;
        }
        nanosleep(&pause, NULL);
    }
    munmap((void *)r, MAP_SIZE);
    close(fd);
    return rc;
}

int pps_ts_disable_frame(void) {
    return frame_write(0x0, 0, 0, 0);
}

#define REG_LATCH_COUNT (0x3C / 4)
#define REG_LATCH_SEQ   (0x40 / 4)

bool pps_ts_latch(const pps_ts_t *p, uint32_t *count, uint32_t *seq, uint64_t *gps_ns) {
    if (!p->regs) return false;
    uint32_t lc   = p->regs[REG_LATCH_COUNT];
    uint32_t ls   = p->regs[REG_LATCH_SEQ];
    uint32_t ppsc = p->regs[REG_PPS_COUNT];
    double cnt = pps_ts_cnt_used(p, p->regs[REG_PPS_DELTA]);
    if (count)  *count  = lc;
    if (seq)    *seq    = ls;
    if (gps_ns) {
        /* SIGNED latch-vs-PPS delta. lc and ppsc are free-running uint32 counts; an
         * unsigned (lc - ppsc) wraps to ~2^32 whenever the latch edge predates the
         * newest PPS (a stale latch, or a PPS landing between edge and read). That
         * wrap divided by cnt_hz stamped anchors ~frac(2^32/cnt_hz) into the second
         * (+0.4967 s at 10 MHz, +0.7484 s at 20 MHz) -- the intermittent late-capture
         * label. Signed, a latch just before the PPS (a read racing the edge by ms)
         * resolves to the correct earlier time; anything staler cannot be this
         * capture's DMA-start edge, so report no-latch (gps_ns = 0) and let the caller
         * fall back to the frame-grid snap, which is grid-correct. */
        int32_t d = (int32_t)(lc - ppsc);
        double  period = cnt;                       /* ~1 s of cnt_clk counts */
        if ((double)d <= -(period * 0.125) || (double)d >= period * 1.125) {
            *gps_ns = 0;                            /* stale/implausible latch */
        } else {
            int64_t off_ns = (int64_t)((double)d / cnt * 1e9 + (d >= 0 ? 0.5 : -0.5));
            *gps_ns = (uint64_t)((int64_t)last_pps_gps_ns() + off_ns);
        }
    }
    return true;
}

void pps_ts_anchor(const pps_ts_t *p, pps_anchor_t *a) {
    if (!p->regs) { a->present = false; a->gps_ns = 0; return; }
    a->pps_count  = p->regs[REG_PPS_COUNT];
    a->live_count = p->regs[REG_LIVE];
    a->pps_seq    = p->regs[REG_PPS_SEQ];
    a->cnt_hz     = p->regs[REG_PPS_DELTA];
    a->present    = (p->regs[REG_STATUS] & 0x1) != 0;
    double cnt_hz = pps_ts_cnt_used(p, a->cnt_hz);
    uint32_t since = a->live_count - a->pps_count;
    a->gps_ns = last_pps_gps_ns() + (uint64_t)((double)since / cnt_hz * 1e9 + 0.5);
}
