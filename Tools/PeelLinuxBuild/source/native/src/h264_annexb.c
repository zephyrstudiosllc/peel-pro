#include "h264_annexb.h"
#include <stdlib.h>
#include <string.h>

static size_t start_code(const uint8_t *p, size_t n, size_t from, size_t *prefix) {
    for (size_t i = from; i + 2 < n; i++) {
        if (p[i] || p[i + 1]) continue;
        if (p[i + 2] == 1) { *prefix = 3; return i; }
        if (i + 3 < n && !p[i + 2] && p[i + 3] == 1) { *prefix = 4; return i; }
    }
    return n;
}
void peel_h264_au_clear(PeelH264AU *u) {
    if (!u) return;
    free(u->avcc); free(u->sps); free(u->pps); memset(u, 0, sizeof(*u));
}
int peel_h264_from_annexb(const uint8_t *p, size_t n, PeelH264AU *u) {
    if (!u) return 0;
    memset(u, 0, sizeof(*u));
    if (!p || !n || n > PEEL_H264_MAX_AU) return 0;
    size_t prefix = 0, at = start_code(p, n, 0, &prefix), count = 0, total = 0;
    if (at == n) return 0;
    for (size_t i = 0; i < at; i++) if (p[i]) return 0;
    /* One additional byte per 3-byte prefix; enforce the final AVCC
     * budget in a first pass before allocation. No unbounded NAL list. */
    for (size_t pass = 0; pass < 2; pass++) {
        size_t cursor = at, code = prefix, output = 0;
        while (cursor < n) {
            size_t begin = cursor + code, next_code = 0;
            size_t next = start_code(p, n, begin, &next_code), end = next;
            while (end > begin && p[end - 1] == 0) end--; /* byte-stream trailing_zero_8bits */
            if (end <= begin) goto invalid;
            size_t size = end - begin;
            unsigned type = p[begin] & 31;
            if ((p[begin] & 128) || !type || type > 23 ||
                ((type == 1 || type == 5 || type == 8) && size < 2) ||
                (type == 7 && size < 4) ||
                ((type == 7 || type == 8) && size > PEEL_H264_MAX_PARAMETER)) goto invalid;
            if (!pass) {
                if (++count > 65536 || size > PEEL_H264_MAX_AU - 4 || total > PEEL_H264_MAX_AU - 4 - size) goto invalid;
                if (type != 7 && type != 8) total += 4 + size;
            } else if (type == 7 || type == 8) {
                uint8_t **parameter = type == 7 ? &u->sps : &u->pps;
                size_t *parameter_length = type == 7 ? &u->sps_length : &u->pps_length;
                if (*parameter) goto invalid; /* ambiguous multi-configuration AU */
                *parameter = malloc(size); if (!*parameter) goto invalid;
                memcpy(*parameter, p + begin, size); *parameter_length = size;
            } else {
                u->avcc[output] = (uint8_t)(size >> 24); u->avcc[output + 1] = (uint8_t)(size >> 16);
                u->avcc[output + 2] = (uint8_t)(size >> 8); u->avcc[output + 3] = (uint8_t)size;
                memcpy(u->avcc + output + 4, p + begin, size);
                if (type >= 1 && type <= 5) u->vcl = 1;
                if (type == 5) u->idr = 1;
                output += 4 + size;
            }
            cursor = next; code = next_code;
        }
        if (!pass) { u->avcc = total ? malloc(total) : NULL; if (total && !u->avcc) goto invalid; u->length = total; }
    }
    return 1;
invalid:
    peel_h264_au_clear(u); return 0;
}

int peel_h264_frame_cost(size_t avcc, size_t sps, size_t pps, size_t *cost) {
    if (!cost || !avcc || !sps || !pps || avcc > PEEL_H264_MAX_AU ||
        sps > PEEL_H264_MAX_PARAMETER || pps > PEEL_H264_MAX_PARAMETER ||
        sps > PEEL_H264_MAX_AU - avcc || pps > PEEL_H264_MAX_AU - avcc - sps) return 0;
    *cost = avcc + sps + pps; return 1;
}
