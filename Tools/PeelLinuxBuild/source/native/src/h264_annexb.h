#pragma once
#include <stddef.h>
#include <stdint.h>
#define PEEL_H264_MAX_AU (8u * 1024u * 1024u)
#define PEEL_H264_MAX_PARAMETER (512u * 1024u)
typedef struct {
    uint8_t *avcc;
    size_t length;
    uint8_t *sps, *pps; /* owned raw parameter sets, omitted from avcc */
    size_t sps_length, pps_length;
    int idr, vcl;
} PeelH264AU;
int peel_h264_from_annexb(const uint8_t *bytes, size_t length, PeelH264AU *result);
void peel_h264_au_clear(PeelH264AU *unit);

int peel_h264_frame_cost(size_t avcc, size_t sps, size_t pps, size_t *cost);
