/*
 * pps_timestamp.c - see pps_timestamp.h. VENDORED verbatim from the DSN/sdr-stack
 * device/streamer (validated on hardware: LIVE_COUNT advances at PPS_DELTA, the
 * counter->GPS-time map agrees with the disciplined system clock).
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
    p->regs = NULL; p->mem_fd = -1; p->nominal_cnt_hz = nominal_cnt_hz;
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

uint32_t pps_ts_cnt_hz(const pps_ts_t *p) {
    return p->regs ? p->regs[REG_PPS_DELTA] : 0;
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
    double   cnt_hz    = (double)p->regs[REG_PPS_DELTA];
    if (cnt_hz < p->nominal_cnt_hz * 0.5 || cnt_hz > p->nominal_cnt_hz * 1.5)
        cnt_hz = p->nominal_cnt_hz;          /* PPS_DELTA not yet valid */
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
    /* enable|pps_sync_en|drive_pins: drive_pins (bit2) is REQUIRED for tdd_enable to
     * output the RX-window level; the BD ORs tdd_enable into the RX-DMA sync, so without
     * it the window never opens. pps_sync_en resets the frame on each PPS -> GPS-locked. */
    return frame_write(0x7, frame_len, rx_start, rx_stop);
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
    double cnt = (double)p->regs[REG_PPS_DELTA];
    if (cnt < p->nominal_cnt_hz * 0.5 || cnt > p->nominal_cnt_hz * 1.5)
        cnt = p->nominal_cnt_hz;
    if (count)  *count  = lc;
    if (seq)    *seq    = ls;
    if (gps_ns) *gps_ns = last_pps_gps_ns() +
                          (uint64_t)((double)(lc - ppsc) / cnt * 1e9 + 0.5);
    return true;
}

void pps_ts_anchor(const pps_ts_t *p, pps_anchor_t *a) {
    if (!p->regs) { a->present = false; a->gps_ns = 0; return; }
    a->pps_count  = p->regs[REG_PPS_COUNT];
    a->live_count = p->regs[REG_LIVE];
    a->pps_seq    = p->regs[REG_PPS_SEQ];
    a->cnt_hz     = p->regs[REG_PPS_DELTA];
    a->present    = (p->regs[REG_STATUS] & 0x1) != 0;
    double cnt_hz = (double)a->cnt_hz;
    if (cnt_hz < p->nominal_cnt_hz * 0.5 || cnt_hz > p->nominal_cnt_hz * 1.5)
        cnt_hz = p->nominal_cnt_hz;
    uint32_t since = a->live_count - a->pps_count;
    a->gps_ns = last_pps_gps_ns() + (uint64_t)((double)since / cnt_hz * 1e9 + 0.5);
}
