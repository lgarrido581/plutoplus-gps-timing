/* =============================================================================
 * iqwire.h - the block header of a GPS-timed IQ stream (radio -> host), version 1.
 *
 * One stream message is two ZMQ frames:
 *   [ iqw_hdr | iqw_marker x n_markers ]   [ samples ]
 * Everything is little-endian. Samples are ci16, interleaved per sample and channel
 * (ch0 I, ch0 Q, ch1 I, ch1 Q, ...), nsamples per channel.
 *
 * Time. A stream is a sequence of epochs. Within an epoch the samples are continuous
 * (sample0 counts them from 0). Sample 0 starts on a PPS edge; epoch_t0_ns is its GPS
 * time as latched in hardware (within a counter tick of the edge, ~+100 ns). Markers
 * place later events in the epoch by the radio's counter: tick counts cnt_clk since
 * sample 0, and ticks_per_sample of them make one sample, so a marker can fall
 * between samples. Each later PPS edge gets a marker (value = its GPS second; one at
 * tick 0 is allowed), so any sample's GPS time follows from the two anchors around
 * it and a drifting sample clock costs nothing.
 *
 * Loss. The radio never delivers a gap inside an epoch: on a DMA overflow (or a lag
 * longer than its queue) it drops the epoch and starts a new one on the next PPS
 * edge. The first block of the new epoch carries IQW_F_EPOCH_START, plus
 * IQW_F_OVERFLOW if the previous epoch ended in a loss.
 * =============================================================================*/
#ifndef IQWIRE_H
#define IQWIRE_H

#include <stdint.h>

#define IQW_MAGIC    0x31575149u   /* bytes 'I' 'Q' 'W' '1' */
#define IQW_VERSION  1u

/* iqw_hdr.flags */
#define IQW_F_EPOCH_START (1u << 0)  /* first block of an epoch (sample0 == 0)          */
#define IQW_F_OVERFLOW    (1u << 1)  /* the previous epoch ended in lost samples         */
#define IQW_F_XO_LOCKED   (1u << 2)  /* the radio's clock discipline was LOCKED at start */
#define IQW_F_LAST        (1u << 3)  /* last block: the stream is stopping               */

/* iqw_hdr.format */
#define IQW_FMT_CI16 1u

/* iqw_marker.kind (readers skip kinds they don't know) */
#define IQW_M_PPS      1u   /* a PPS edge; value = its GPS second                     */
#define IQW_M_TX_START 2u   /* a cyclic TX buffer started; value = its length, samples */
#define IQW_M_GAIN     3u   /* RX gain from this tick on; value = milli-dB (AGC: -1)  */
#define IQW_M_TX_HASH  4u   /* the TX buffer that started here; value = 64-bit hash   */

typedef struct {
    uint32_t magic;            /* IQW_MAGIC                                          */
    uint16_t version;          /* IQW_VERSION                                        */
    uint16_t hdr_bytes;        /* sizeof(iqw_hdr) + n_markers * sizeof(iqw_marker)   */
    uint32_t seq;              /* block number in the stream, all epochs (wraps)     */
    uint32_t flags;            /* IQW_F_*                                            */
    uint32_t epoch;            /* epoch number, from 0                               */
    uint16_t channels;         /* 1 or 2                                             */
    uint16_t format;           /* IQW_FMT_*                                          */
    uint64_t sample0;          /* index of this block's first sample in the epoch    */
    uint32_t nsamples;         /* samples per channel in this block                  */
    uint16_t n_markers;        /* iqw_marker entries after this header               */
    uint16_t ticks_per_sample; /* radio counter ticks per sample (l_clk multiple)    */
    double   sample_rate_hz;   /* actual rate the radio reports                      */
    double   center_freq_hz;   /* actual LO the radio reports                        */
    uint64_t epoch_t0_ns;      /* GPS ns of the epoch's sample 0 (a PPS edge)        */
} iqw_hdr;                     /* 64 bytes */

typedef struct {
    uint64_t tick;             /* radio counter ticks since the epoch's sample 0     */
    int64_t  value;            /* per kind (GPS second, TX length, ...)              */
    uint32_t kind;             /* IQW_M_*                                            */
    uint32_t rsvd;
} iqw_marker;                  /* 24 bytes */

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(iqw_hdr) == 64, "iqw_hdr must be 64 bytes");
_Static_assert(sizeof(iqw_marker) == 24, "iqw_marker must be 24 bytes");
#endif

#endif /* IQWIRE_H */
