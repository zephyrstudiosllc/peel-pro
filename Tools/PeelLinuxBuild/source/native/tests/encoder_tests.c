#include "peel_linux.h"
#include "encoder_internal.h"
#include "h264_annexb.h"
#include <gst/video/video.h>
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static unsigned assertions;
#define REQUIRE(x) do { assertions++; if (!(x)) { fprintf(stderr, "Assertion failed at %s:%d: %s\n", __FILE__, __LINE__, #x); return 1; } } while (0)
typedef struct {
    uint64_t source, encoder;
    unsigned delivered, rejected, failures, observed, keyframes;
    gboolean reject_first, invalid, recovering;
    int64_t last_pts, last_duration;
    uint64_t last_configuration;
    gboolean last_configuration_changed;
    GBytes *last_sps, *last_pps;
    unsigned callbacks;
    uint64_t invalid_mask;
} State;
static void observed(const PeelCaptureInfo *capture, void *data) {
    State *state = data; state->observed++;
    if (capture->active && (!capture->source_generation || capture->source_id != 1 || !capture->width || !capture->height)) state->invalid = TRUE;
}
/* Diagnostics are confined to these owned synthetic fixtures. At most the
 * first16 callbacks are described, with no pixels, pointers, keys or payload. */
static void invalid_frame(State *state, uint64_t bit, const char *reason) {
    state->invalid = TRUE; state->invalid_mask |= bit;
    if (state->callbacks <= 16) fprintf(stderr, "synthetic-invalid bit=0x%" PRIx64 " reason=%s\n", bit, reason);
}
static void failed(uint64_t source, uint64_t encoder, void *data) {
    State *state = data;
    if (source != state->source || encoder != state->encoder) state->invalid = TRUE;
    state->failures++;
    fprintf(stderr, "synthetic-failure source=%" PRIu64 "/%" PRIu64 " encoder=%" PRIu64 "/%" PRIu64
        " delivered=%u rejected=%u callbacks=%u invalid=%d mask=0x%" PRIx64 "\n",
        source, state->source, encoder, state->encoder, state->delivered, state->rejected,
        state->callbacks, state->invalid, state->invalid_mask);
}
static int delivered(const PeelEncodedFrame *frame, void *data) {
    State *state = data;
    state->callbacks++;
    if (state->callbacks <= 16) fprintf(stderr,
        "synthetic-output callback=%u source=%" PRIu64 "/%" PRIu64 " encoder=%" PRIu64 "/%" PRIu64
        " config=%" PRIu64 " sourceID=%u dims=%ux%u timescale=%u pts=%" PRId64 " priorPTS=%" PRId64
        " duration=%" PRId64 " keyframe=%d configChanged=%d avcc=%zu sps=%zu pps=%zu recovering=%d\n",
        state->callbacks, frame->source_generation, state->source, frame->encoder_generation, state->encoder,
        frame->configuration_generation, frame->source_id, frame->width, frame->height, frame->timescale,
        frame->pts_ns, state->last_pts, frame->duration_ns, frame->keyframe, frame->configuration_changed,
        frame->avcc_length, frame->sps_length, frame->pps_length, state->recovering);
    if (frame->source_generation != state->source) invalid_frame(state, UINT64_C(1) << 0, "source_generation");
    if (frame->encoder_generation != state->encoder) invalid_frame(state, UINT64_C(1) << 1, "encoder_generation");
    if (frame->source_id != 1) invalid_frame(state, UINT64_C(1) << 2, "source_id");
    if (frame->width != 320 || frame->height != 240) invalid_frame(state, UINT64_C(1) << 3, "dimensions");
    if (frame->timescale != 1000000000) invalid_frame(state, UINT64_C(1) << 4, "timescale");
    if (frame->pts_ns < 0) invalid_frame(state, UINT64_C(1) << 5, "negative_pts");
    if (frame->duration_ns < 0) invalid_frame(state, UINT64_C(1) << 6, "negative_duration");
    if (frame->pts_ns < state->last_pts) invalid_frame(state, UINT64_C(1) << 7, "pts_regression");
    if (!frame->configuration_generation) invalid_frame(state, UINT64_C(1) << 8, "zero_configuration_generation");
    if (frame->avcc_length > PEEL_H264_MAX_AU || frame->sps_length > PEEL_H264_MAX_AU - frame->avcc_length ||
        frame->pps_length > PEEL_H264_MAX_AU - frame->avcc_length - frame->sps_length)
        invalid_frame(state, UINT64_C(1) << 9, "combined_payload_budget");
    if (frame->sps_length < 4 || frame->pps_length < 2 || (frame->sps[0] & 31) != 7 || (frame->pps[0] & 31) != 8)
        invalid_frame(state, UINT64_C(1) << 10, "parameter_set_shape");
    size_t at = 0; gboolean idr = FALSE;
    while (at < frame->avcc_length) {
        if (frame->avcc_length - at < 4) { invalid_frame(state, UINT64_C(1) << 11, "avcc_short_length"); break; }
        uint32_t size = ((uint32_t)frame->avcc[at] << 24) | ((uint32_t)frame->avcc[at + 1] << 16) |
            ((uint32_t)frame->avcc[at + 2] << 8) | frame->avcc[at + 3]; at += 4;
        if (!size || size > frame->avcc_length - at) { invalid_frame(state, UINT64_C(1) << 12, "avcc_nal_bounds"); break; }
        if ((frame->avcc[at] & 31) == 5) idr = TRUE;
        at += size;
    }
    if (idr != !!frame->keyframe) invalid_frame(state, UINT64_C(1) << 13, "actual_idr_vs_keyframe_flag");
    if ((state->delivered == 0 || state->recovering) && (!idr || !frame->configuration_changed))
        invalid_frame(state, UINT64_C(1) << 14, "initial_or_recovery_idr_configuration");
    if (idr) state->keyframes++;
    state->last_pts = frame->pts_ns;
    state->last_duration = frame->duration_ns;
    state->last_configuration = frame->configuration_generation;
    state->last_configuration_changed = frame->configuration_changed;
    g_clear_pointer(&state->last_sps, g_bytes_unref);
    g_clear_pointer(&state->last_pps, g_bytes_unref);
    state->last_sps = g_bytes_new(frame->sps, frame->sps_length);
    state->last_pps = g_bytes_new(frame->pps, frame->pps_length);
    if (state->reject_first && !state->rejected) { state->rejected++; state->recovering = TRUE; return 0; }
    state->recovering = FALSE; state->delivered++; return 1;
}
static GstSample *raw_sample(unsigned width, unsigned height, uint64_t pts) {
    GstCaps *caps = gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, "BGRA",
        "width", G_TYPE_INT, width, "height", G_TYPE_INT, height, "framerate", GST_TYPE_FRACTION, 30, 1, NULL);
    GstVideoInfo info; gst_video_info_from_caps(&info, caps);
    GstBuffer *buffer = gst_buffer_new_allocate(NULL, info.size, NULL);
    gst_buffer_memset(buffer, 0, (int)(pts / 33333333) & 255, info.size);
    GST_BUFFER_PTS(buffer) = pts; GST_BUFFER_DURATION(buffer) = 33333333;
    GstSample *sample = gst_sample_new(buffer, caps, NULL, NULL); gst_buffer_unref(buffer); gst_caps_unref(caps); return sample;
}
static void iterate(void) { while (g_main_context_iteration(NULL, FALSE)) {} }
static void feed(uint64_t source, unsigned width, unsigned height, uint64_t pts) {
    GstSample *sample = raw_sample(width, height, pts); peel_encoder_capture_sample(source, sample); gst_sample_unref(sample);
}
static gboolean wait_callbacks(State *state, unsigned delivered_count, unsigned rejected_count, const char *stage) {
    gint64 started = g_get_monotonic_time(), deadline = started + 3000000;
    while ((state->delivered < delivered_count || state->rejected < rejected_count) &&
        !state->failures && g_get_monotonic_time() < deadline) {
        iterate(); g_usleep(1000);
    }
    gboolean ok = state->delivered >= delivered_count && state->rejected >= rejected_count && !state->failures && !state->invalid;
    if (!ok) fprintf(stderr,
        "synthetic-wait-failed stage=%s elapsed_us=%" G_GINT64_FORMAT
        " expected_delivered=%u actual_delivered=%u expected_rejected=%u actual_rejected=%u"
        " failures=%u invalid=%d mask=0x%" PRIx64 " callbacks=%u idrs=%u lastPTS=%" PRId64 " reason=%s\n",
        stage, g_get_monotonic_time() - started, delivered_count, state->delivered, rejected_count, state->rejected,
        state->failures, state->invalid, state->invalid_mask, state->callbacks, state->keyframes, state->last_pts,
        state->failures ? "native_failure_callback" : state->invalid ? "invalid_delivered_frame" : "deadline_without_enough_callbacks");
    return ok;
}
static void released(gpointer user, GstMiniObject *object) { (void)object; (*(unsigned *)user)++; }
int main(int argc, char **argv) {
    gst_init(&argc, &argv);
    /* Pure byte-contract cases: mixed prefixes, legal leading/trailing zeros,
     * malformed bounds/header, ambiguous parameter sets and config/keyframe. */
    const uint8_t annex[] = {0,0,0,0,1,0x67,0x42,0,0x1e,0,0,1,0x68,0xce,0,0,0,1,0x65,0x88,0,0};
    PeelH264AU unit;
    REQUIRE(peel_h264_from_annexb(annex, sizeof(annex), &unit));
    REQUIRE(unit.idr && unit.vcl && unit.sps_length == 4 && unit.pps_length == 2 && unit.length == 6);
    REQUIRE(unit.avcc[3] == 2 && unit.avcc[4] == 0x65 && unit.avcc[5] == 0x88); peel_h264_au_clear(&unit);
    const uint8_t empty[] = {0,0,1}, forbidden[] = {0,0,1,0xe5,1}, short_vcl[] = {0,0,1,0x65};
    REQUIRE(!peel_h264_from_annexb(empty, sizeof(empty), &unit));
    REQUIRE(!peel_h264_from_annexb(forbidden, sizeof(forbidden), &unit));
    REQUIRE(!peel_h264_from_annexb(short_vcl, sizeof(short_vcl), &unit));
    const uint8_t duplicate[] = {0,0,1,0x67,0x42,0,0x1e,0,0,1,0x67,0x42,0,0x1e};
    REQUIRE(!peel_h264_from_annexb(duplicate, sizeof(duplicate), &unit));
    REQUIRE(!peel_h264_from_annexb(annex, PEEL_H264_MAX_AU + (size_t)1, &unit));
    REQUIRE(!peel_h264_from_annexb(NULL, 1, &unit));
    /* The production queue-cost function includes each retained parameter set,
     * even when shared internally. Exactly 8 MiB is valid; one extra byte is not. */
    size_t cost = 0;
    REQUIRE(peel_h264_frame_cost(PEEL_H264_MAX_AU - 2 * PEEL_H264_MAX_PARAMETER,
        PEEL_H264_MAX_PARAMETER, PEEL_H264_MAX_PARAMETER, &cost) && cost == PEEL_H264_MAX_AU);
    REQUIRE(!peel_h264_frame_cost(PEEL_H264_MAX_AU - 2 * PEEL_H264_MAX_PARAMETER + 1,
        PEEL_H264_MAX_PARAMETER, PEEL_H264_MAX_PARAMETER, &cost));
    REQUIRE(peel_h264_frame_cost(PEEL_H264_MAX_AU - 6, 4, 2, &cost) && cost == PEEL_H264_MAX_AU);
    REQUIRE(!peel_h264_frame_cost(PEEL_H264_MAX_AU - 5, 4, 2, &cost));
    REQUIRE(!peel_h264_frame_cost(1, PEEL_H264_MAX_PARAMETER + 1, 2, &cost));
    REQUIRE(!peel_h264_frame_cost(SIZE_MAX, 4, 2, &cost));
    REQUIRE(!peel_h264_frame_cost(1, 4, 0, &cost));
    REQUIRE(!peel_h264_frame_cost(1, 4, 2, NULL));

    /* Real encoder-only integration in the hosted build environment: owned
     * synthetic BGRA samples, no GTK initialization/display/portal/socket. */
    REQUIRE(g_main_context_acquire(g_main_context_default()));
    State state = { .source = 41 };
    REQUIRE(peel_linux_host_observe(observed, &state));
    REQUIRE(peel_linux_h264_encoder_available());
    REQUIRE(peel_linux_host_encoder_start(41, 1000000, 2, delivered, failed, &state) == 0);
    peel_encoder_capture_open(41, 1);
    PeelCaptureInfo capture;
    REQUIRE(!peel_linux_host_get_capture(&capture));
    feed(40, 320, 240, 0); REQUIRE(!peel_linux_host_get_capture(&capture));
    feed(41, 320, 240, 0); iterate(); REQUIRE(peel_linux_host_get_capture(&capture));
    REQUIRE(capture.width == 320 && capture.height == 240 && capture.source_generation == 41);
    REQUIRE(peel_linux_host_encoder_start(40, 1000000, 2, delivered, failed, &state) == 0);
    state.encoder = peel_linux_host_encoder_start(41, 1000000, 2, delivered, failed, &state);
    REQUIRE(state.encoder != 0);
    /* The only raw sample was supplied BEFORE attachment. No following damage
     * is fed during these waits: Start must seed the retained real sample. */
    REQUIRE(wait_callbacks(&state, 1, 0, "static_initial_seed"));
    REQUIRE(state.last_pts == 0 && state.rejected == 0 && state.keyframes == 1);
    uint64_t initial_configuration = state.last_configuration;
    GBytes *initial_sps = g_bytes_ref(state.last_sps), *initial_pps = g_bytes_ref(state.last_pps);
    REQUIRE(initial_configuration != 0 && state.last_configuration_changed && state.last_duration == 33333333);
    REQUIRE(peel_linux_host_encoder_request_keyframe(41, state.encoder));
    REQUIRE(wait_callbacks(&state, 2, 0, "explicit_same_pts_replay"));
    REQUIRE(state.last_pts == 0 && state.keyframes == 2); /* actual PTS, never invented time */
    REQUIRE(state.last_configuration == initial_configuration && state.last_configuration_changed &&
        state.last_duration == 33333333 && g_bytes_equal(initial_sps, state.last_sps) &&
        g_bytes_equal(initial_pps, state.last_pps)); /* actual repeated config, not an event receipt */
    /* Explicit current-generation recovery after a whole-AU sink rejection.
     * This proves native equal-PTS IDR output only. A strict-increasing network
     * consumer must start a fresh encoder epoch for static replay acceptance. */
    state.reject_first = TRUE;
    REQUIRE(peel_linux_host_encoder_request_keyframe(41, state.encoder));
    REQUIRE(wait_callbacks(&state, 2, 1, "explicit_replay_sink_reject"));
    REQUIRE(state.recovering);
    REQUIRE(peel_linux_host_encoder_request_keyframe(41, state.encoder));
    REQUIRE(wait_callbacks(&state, 3, 1, "explicit_replay_recovery"));
    REQUIRE(!state.recovering && state.last_pts == 0 && state.keyframes == 4);
    REQUIRE(state.last_configuration == initial_configuration && state.last_configuration_changed &&
        g_bytes_equal(initial_sps, state.last_sps) && g_bytes_equal(initial_pps, state.last_pps));
    /* After equal-PTS native replay, a new real source timestamp must pass
     * through exactly: no replacement with running time or synthetic +1. */
    feed(41, 320, 240, 33333333);
    REQUIRE(wait_callbacks(&state, 4, 1, "next_increasing_actual_source_pts"));
    REQUIRE(state.last_pts == 33333333 && state.last_duration == 33333333 &&
        state.last_configuration == initial_configuration);
    /* A strict-increasing managed consumer recovers static content only with
     * a new encoder/admission epoch. Start alone seeds the retained real sample
     * at the same actual time, and its first delivered AU must be config+IDR. */
    uint64_t retired_encoder = state.encoder;
    unsigned keyframes_before_restart = state.keyframes;
    state.recovering = TRUE;
    state.encoder = peel_linux_host_encoder_start(41, 1000000, 2, delivered, failed, &state);
    REQUIRE(state.encoder != 0 && state.encoder != retired_encoder);
    REQUIRE(wait_callbacks(&state, 5, 1, "new_encoder_same_actual_source_pts"));
    REQUIRE(state.last_pts == 33333333 && state.last_duration == 33333333 &&
        state.keyframes == keyframes_before_restart + 1 && state.last_configuration_changed && !state.recovering);
    REQUIRE(!peel_linux_host_encoder_stop(41, retired_encoder));
    g_bytes_unref(initial_sps); g_bytes_unref(initial_pps);
    REQUIRE(!peel_linux_host_encoder_stop(41, state.encoder + 1));
    feed(41, 322, 240, 33333333);
    /* Actual latest caps change before the pending GTK publication. Neither a
     * new old-size encoder nor a replay into the old encoder may admit it. */
    REQUIRE(!peel_linux_host_encoder_request_keyframe(41, state.encoder));
    REQUIRE(peel_linux_host_encoder_start(41, 1000000, 2, delivered, failed, &state) == 0);
    iterate();
    REQUIRE(peel_linux_host_get_capture(&capture) && capture.width == 322);
    REQUIRE(!state.failures && !state.invalid);
    REQUIRE(!peel_linux_host_encoder_stop(41, state.encoder)); /* already retired before observer */
    unsigned delivered_before_stop = state.delivered;
    state.failures = 0; state.last_pts = 0; state.source = 42;
    peel_encoder_capture_close(41); peel_encoder_capture_open(42, 1); feed(42, 320, 240, 0); iterate();
    state.encoder = peel_linux_host_encoder_start(42, 1000000, 2, delivered, failed, &state); REQUIRE(state.encoder != 0);
    /* Let codec threads queue without pumping delivery, then revoke. A queued
     * old IDR/P frame must not call the owner after synchronous source close. */
    for (unsigned i = 1; i <= 15; i++) { feed(42, 320, 240, i * (uint64_t)33333333); g_usleep(5000); }
    peel_encoder_capture_close(42);
    REQUIRE(!peel_linux_host_get_capture(&capture));
    REQUIRE(peel_linux_host_encoder_start(42, 1000000, 2, delivered, failed, &state) == 0);
    for (unsigned i = 0; i < 20; i++) { iterate(); g_usleep(1000); }
    REQUIRE(state.delivered == delivered_before_stop && !state.failures);
    REQUIRE(peel_linux_host_observe(NULL, NULL));
    unsigned observations = state.observed;
    peel_encoder_capture_open(43, 0);
    GstSample *retained = raw_sample(320, 240, 0); unsigned sample_released = 0;
    gst_mini_object_weak_ref(GST_MINI_OBJECT(gst_sample_get_buffer(retained)), released, &sample_released);
    peel_encoder_capture_sample(43, retained); gst_sample_unref(retained); iterate();
    REQUIRE(sample_released == 0); /* sole retained latest sample, no encoder */
    peel_encoder_capture_close(43);
    REQUIRE(sample_released == 1); /* source revoke releases it before return */
    peel_encoder_capture_open(44, 0);
    REQUIRE(!peel_linux_host_get_capture(&capture));
    REQUIRE(peel_linux_host_encoder_start(44, 1000000, 2, delivered, failed, &state) == 0);
    feed(43, 320, 240, 33333333); iterate();
    REQUIRE(!peel_linux_host_get_capture(&capture)); /* old grant cannot reseed */
    peel_encoder_capture_close(44); iterate();
    REQUIRE(state.observed == observations);
    g_main_context_release(g_main_context_default());
    g_clear_pointer(&state.last_sps, g_bytes_unref); g_clear_pointer(&state.last_pps, g_bytes_unref);
    printf("Native encoder seam: %u assertions passed; real synthetic H264 only, no portal/network/device/parity proof.\n", assertions);
    return 0;
}
