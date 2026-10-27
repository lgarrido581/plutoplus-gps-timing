/*
 * dechirp_pl.h - the optional PL dechirp_decim block (stretch processing in the FPGA).
 *
 * A bitstream built with the dechirp_decim HDL overlay has a block between the AD9361
 * core's RX output and the RX DMA. It mixes each RX sample with the conjugate of the TX
 * word the DAC sent ALIGN + 1 strobes earlier, CIC3-decimates by D = 2^k with the filter
 * zeroed at every sweep start, and hands the DMA fs/D sweep-aligned ci16 samples. A
 * sweep start is where the replica's words (n-1, n) equal PAT0/PAT1: the loaded TX
 * buffer's first two words. CTRL.bypass (set at power-up) makes the block a wire, so
 * the same bitstream serves raw captures and streams unchanged.
 *
 * Presence. The block exists only on such a bitstream; a read of an unmapped AXI slave
 * aborts. So the block is touched only when /etc/plutoplus/pl_features (packed into the
 * same FIT as the bitstream) lists `dechirp_decim <base> v1`, and then only if its ID
 * register reads "DCDM".
 *
 * Registers (AXI4-Lite, base 0x7C470000; radar-stack docs/PL_DECHIRP_DECIM.md section 4):
 *   0x00 ID          RO 0x4443444D "DCDM"
 *   0x04 VERSION     RO 31..24 major, 23..16 minor, 15..8 max log2 D, 7..0 CIC order
 *                    (this daemon needs 1.1+: the sync-edge re-arm)
 *   0x08 CTRL        bit0 enable, bit1 bypass (reset 1), bit2 detector_en (reset 1),
 *                    bit3 tdd_phase, bit4 soft_reset (self-clearing)
 *   0x0C DECIM       log2 D
 *   0x10 SWEEP_LEN   input samples per sweep (24 bits)
 *   0x14 ALIGN       replica delay beyond one strobe, 0..4094
 *   0x18 PAT0        TX buffer word 0 (I 15..0, Q 31..16)
 *   0x1C STATUS      bit0 locked, bit1 running, bit2 saturated (sticky), 31..16 outputs/sweep
 *   0x20 PERIOD      RO last measured sweep period, input samples
 *   0x28 S0          RO input index (from the epoch's sync edge) of output sample 0
 *   0x2C SAT_COUNT   RO saturations since soft_reset
 *   0x30 PAT1        TX buffer word 1
 *   0x34 PERIOD_ERR  RO starts not SWEEP_LEN after the previous one (sticky, saturating)
 * Configure with enable = 0, then set enable: the configuration crosses into l_clk as
 * static wires, and so does the status on the way back, so a status read can catch a
 * value mid-change (dcdm_read reads each until two agree).
 */
#ifndef DECHIRP_PL_H
#define DECHIRP_PL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DCDM_FEATURES  "/etc/plutoplus/pl_features"
#define DCDM_ID_WORD   0x4443444Du    /* "DCDM" */

typedef struct {
    int      present;      /* feature file lists it and the ID matched */
    uint32_t base;         /* AXI address from the feature file */
    uint32_t version;      /* VERSION register */
    int      max_log2d;    /* from VERSION */
    char     why[96];      /* why not present (for logs) */
} dcdm_info_t;

/* The block's registers, one read each. */
typedef struct {
    int      locked, running, saturated;
    unsigned outs_per_sweep;
    uint32_t period, s0, sat_count, period_err;
} dcdm_state_t;

/* Look for the block once (the bitstream cannot change under a running daemon) and keep
 * its page mapped. Every call returns the cached answer. 1 = present. */
int  dcdm_probe(dcdm_info_t *out);

/* Configure for a stream: CTRL = bypass (enable 0), soft_reset, DECIM, SWEEP_LEN, ALIGN,
 * PAT0, PAT1 (each read back), then bypass cleared with enable still 0, so the DMA gets
 * nothing until dcdm_enable(1). 0 ok, -1 with err set. */
int  dcdm_configure(int log2d, uint32_t sweep_len, uint32_t align, uint32_t pat0,
                    uint32_t pat1, char *err, size_t errlen);

/* CTRL.enable on or off, bypass kept clear. From VERSION 1.1 every rising edge of the
 * RX-DMA sync re-arms the block (output gated, pipeline cleared, S0 re-latched at the
 * first sweep start after the edge), so a stream enables once, before its first arm.
 * Off resets the sweep state; the sticky counters stay. */
void dcdm_enable(int on);

/* CTRL back to its power-up value (bypass | detector_en): the raw path. A no-op without
 * the block. */
void dcdm_bypass(void);

/* Read the status registers. -1 without the block. */
int  dcdm_read(dcdm_state_t *st);

#ifdef __cplusplus
}
#endif

#endif /* DECHIRP_PL_H */
