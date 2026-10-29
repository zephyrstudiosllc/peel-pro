#include "internal.h"
#include "encoder_internal.h"
#include "h264_annexb.h"
#include <gst/video/video-event.h>
#include <limits.h>
#include <string.h>

_Static_assert(sizeof(void *) == 8, "Peel Linux host ABI requires a supported 64-bit target");
_Static_assert(sizeof(PeelCaptureInfo) == 32, "Capture callback ABI must match the managed bridge");
_Static_assert(sizeof(PeelEncodedFrame) == 112 && offsetof(PeelEncodedFrame, avcc) == 64,
    "Encoded callback ABI must match the managed bridge");

typedef struct {
    GBytes *avcc, *sps, *pps;
    size_t cost;
    uint64_t configuration;
    int64_t pts, duration;
    gboolean idr;
} Encoded;
typedef struct Encoder {
    gatomicrefcount refs;
    GMutex lock;
    gboolean closed, failed, failure_delivered, scheduled, waiting_idr, request_keyframe;
    uint64_t source_generation, generation, configuration, delivered_configuration, recovery_serial;
    uint32_t width, height;
    GstClockTime last_input_pts, last_output_pts;
    GstElement *pipeline, *source, *codec, *sink;
    guint bus_watch;
    GQueue queue;
    size_t queued_bytes;
    GBytes *sps, *pps;
    PeelEncodedSink deliver;
    PeelEncoderFailed failure;
    void *user;
} Encoder;
static GMutex registry;
static Encoder *current_encoder;
static uint64_t next_encoder_generation;
static PeelCaptureInfo capture, pending_capture;
static GstSample *latest_sample; /* exactly one owned raw sample of this grant */
static uint64_t latest_generation;
static uint32_t latest_width, latest_height;
static gboolean capture_pending;
static void encoder_shutdown(Encoder *e);
static PeelCaptureChanged capture_changed;
static void *capture_user;
static gboolean capture_notice_queued;
static gboolean on_main(void) { return g_main_context_is_owner(g_main_context_default()); }
static Encoder *encoder_ref(Encoder *e) { g_atomic_ref_count_inc(&e->refs); return e; }
static void encoded_free(Encoded *f) {
    g_bytes_unref(f->avcc); g_bytes_unref(f->sps); g_bytes_unref(f->pps); g_free(f);
}
static void clear_queue(Encoder *e) { g_queue_clear_full(&e->queue, (GDestroyNotify)encoded_free); e->queued_bytes = 0; }
static void encoder_unref(Encoder *e) {
    if (!g_atomic_ref_count_dec(&e->refs)) return;
    clear_queue(e); g_clear_pointer(&e->sps, g_bytes_unref); g_clear_pointer(&e->pps, g_bytes_unref);
    g_mutex_clear(&e->lock); g_free(e);
}
static gboolean is_current(Encoder *e) {
    g_mutex_lock(&registry);
    gboolean value = current_encoder == e && capture.active && capture.source_generation == e->source_generation &&
        capture.width == e->width && capture.height == e->height;
    g_mutex_unlock(&registry); return value;
}
static void notify_capture_now(void) {
    PeelCaptureInfo value;
    g_mutex_lock(&registry); value = capture; g_mutex_unlock(&registry);
    if (capture_changed) capture_changed(&value, capture_user);
}
static gboolean capture_notice(gpointer unused) {
    (void)unused; Encoder *retired = NULL;
    g_mutex_lock(&registry); capture_notice_queued = FALSE;
    if (capture_pending && pending_capture.source_generation == capture.source_generation) {
        capture = pending_capture;
        if (current_encoder && (capture.width != current_encoder->width || capture.height != current_encoder->height)) {
            retired = current_encoder; current_encoder = NULL;
        }
    }
    capture_pending = FALSE; g_mutex_unlock(&registry);
    /* Format publication, encoder retirement and observer admission are one
     * main-context operation. Codec threads never change published authority. */
    if (retired) encoder_shutdown(retired);
    notify_capture_now(); return G_SOURCE_REMOVE;
}
static void queue_capture_notice_locked(void) {
    if (!capture_notice_queued) { capture_notice_queued = TRUE; g_idle_add(capture_notice, NULL); }
}
int peel_linux_host_observe(PeelCaptureChanged changed, void *user) {
    if (!on_main()) return 0;
    capture_changed = changed; capture_user = user;
    if (changed) notify_capture_now();
    return 1;
}
int peel_linux_host_get_capture(PeelCaptureInfo *value) {
    if (!value) return 0;
    memset(value, 0, sizeof(*value));
    if (!on_main()) return 0;
    g_mutex_lock(&registry); *value = capture; g_mutex_unlock(&registry);
    return value->active;
}
int peel_linux_h264_encoder_available(void) {
    if (!gst_is_initialized()) return 0;
    const char *names[] = { "appsrc", "videoconvert", "openh264enc", "appsink" };
    for (size_t i = 0; i < G_N_ELEMENTS(names); i++) {
        GstElementFactory *factory = gst_element_factory_find(names[i]);
        if (!factory) return 0;
        gst_object_unref(factory);
    }
    return 1;
}
static gboolean drain_encoded(gpointer data);
static void schedule_locked(Encoder *e) {
    if (!e->scheduled) {
        e->scheduled = TRUE;
        g_idle_add_full(G_PRIORITY_DEFAULT, drain_encoded, encoder_ref(e), (GDestroyNotify)encoder_unref);
    }
}
static void fail_at_locked(Encoder *e, const char *function, int line) {
    if (e->closed) return;
    /* Failure-only content-free diagnostics. The test enables this named debug
     * domain; successful frames do not log or change admission/queue policy. */
    if (!e->failed) g_log("PeelLinuxEncoder", G_LOG_LEVEL_DEBUG,
        "failure-site function=%s line=%d source=%" G_GUINT64_FORMAT
        " encoder=%" G_GUINT64_FORMAT " config=%" G_GUINT64_FORMAT
        " inputPTS=%" G_GUINT64_FORMAT " outputPTS=%" G_GUINT64_FORMAT,
        function, line, (guint64)e->source_generation, (guint64)e->generation,
        (guint64)e->configuration, (guint64)e->last_input_pts, (guint64)e->last_output_pts);
    e->failed = TRUE; clear_queue(e); schedule_locked(e);
}
#define fail_locked(encoder) fail_at_locked((encoder), __func__, __LINE__)
static void recover_locked(Encoder *e) {
    clear_queue(e); e->waiting_idr = TRUE; e->request_keyframe = TRUE; e->delivered_configuration = 0;
    if (e->recovery_serial == UINT64_MAX) fail_locked(e);
    else e->recovery_serial++;
}
static void force_keyframe(GstElement *codec) {
    GstPad *pad = gst_element_get_static_pad(codec, "src");
    if (pad) {
        /* Upstream request on the encoder's source pad, never a raw-frame drop
         * pretending to be an IDR. Natural bounded GOP remains the fallback. */
        gst_pad_send_event(pad, gst_video_event_new_upstream_force_key_unit(GST_CLOCK_TIME_NONE, TRUE, 0));
        gst_object_unref(pad);
    }
}
static gboolean encoder_bus(GstBus *bus, GstMessage *message, gpointer data) {
    (void)bus; Encoder *e = data;
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR || GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) {
        g_mutex_lock(&e->lock); fail_locked(e); g_mutex_unlock(&e->lock);
    }
    return G_SOURCE_CONTINUE;
}
static GstFlowReturn encoded_sample(GstAppSink *sink, gpointer data) {
    Encoder *e = data; GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_OK;
    GstBuffer *buffer = gst_sample_get_buffer(sample); GstMapInfo map;
    GstCaps *sample_caps = gst_sample_get_caps(sample);
    const GstStructure *caps = sample_caps && !gst_caps_is_empty(sample_caps) ? gst_caps_get_structure(sample_caps, 0) : NULL;
    int width = 0, height = 0;
    const char *format = caps ? gst_structure_get_string(caps, "stream-format") : NULL;
    const char *alignment = caps ? gst_structure_get_string(caps, "alignment") : NULL;
    gboolean valid = buffer && caps && gst_structure_get_int(caps, "width", &width) && gst_structure_get_int(caps, "height", &height) &&
        width == (int)e->width && height == (int)e->height && g_strcmp0(format, "byte-stream") == 0 &&
        g_strcmp0(alignment, "au") == 0 && GST_BUFFER_PTS_IS_VALID(buffer) &&
        GST_BUFFER_PTS(buffer) <= INT64_MAX &&
        (!GST_BUFFER_DURATION_IS_VALID(buffer) || GST_BUFFER_DURATION(buffer) <= INT64_MAX - GST_BUFFER_PTS(buffer));
    gboolean metadata_valid = valid, mapped = FALSE, parsed = FALSE;
    PeelH264AU unit = {0};
    if (valid && (mapped = gst_buffer_map(buffer, &map, GST_MAP_READ))) {
        valid = parsed = peel_h264_from_annexb(map.data, map.size, &unit); gst_buffer_unmap(buffer, &map);
    } else valid = FALSE;
    g_mutex_lock(&e->lock);
    if (e->closed || e->failed) goto done;
    if (!valid || (e->last_output_pts != GST_CLOCK_TIME_NONE && GST_BUFFER_PTS(buffer) < e->last_output_pts)) {
        g_log("PeelLinuxEncoder", G_LOG_LEVEL_DEBUG,
            "sample-validation metadata=%d mapped=%d parsed=%d actual=%dx%d expected=%ux%u"
            " byteStream=%d auAligned=%d ptsValid=%d pts=%" G_GUINT64_FORMAT
            " durationValid=%d duration=%" G_GUINT64_FORMAT
            " vcl=%d idr=%d avcc=%zu sps=%zu pps=%zu",
            metadata_valid, mapped, parsed, width, height, e->width, e->height,
            g_strcmp0(format, "byte-stream") == 0, g_strcmp0(alignment, "au") == 0,
            buffer && GST_BUFFER_PTS_IS_VALID(buffer),
            buffer ? (guint64)GST_BUFFER_PTS(buffer) : (guint64)GST_CLOCK_TIME_NONE,
            buffer && GST_BUFFER_DURATION_IS_VALID(buffer),
            buffer ? (guint64)GST_BUFFER_DURATION(buffer) : (guint64)GST_CLOCK_TIME_NONE,
            unit.vcl, unit.idr, unit.length, unit.sps_length, unit.pps_length);
        fail_locked(e); goto done;
    }
    if (!unit.vcl) goto done; /* parser repeats headers with IDR; never emit fake frame */
    e->last_output_pts = GST_BUFFER_PTS(buffer);
    if (unit.idr) {
        /* This fixed OpenH264 encoder must supply both actual sets on a recoverable IDR. */
        if (!unit.sps || !unit.pps) { recover_locked(e); goto done; }
        GBytes *sps = g_bytes_new(unit.sps, unit.sps_length), *pps = g_bytes_new(unit.pps, unit.pps_length);
        gboolean changed = !e->sps || !e->pps || !g_bytes_equal(sps, e->sps) || !g_bytes_equal(pps, e->pps);
        if (changed) {
            if (e->configuration == UINT64_MAX) { g_bytes_unref(sps); g_bytes_unref(pps); fail_locked(e); goto done; }
            g_clear_pointer(&e->sps, g_bytes_unref); g_clear_pointer(&e->pps, g_bytes_unref);
            e->sps = g_bytes_ref(sps); e->pps = g_bytes_ref(pps); e->configuration++;
            recover_locked(e);
        }
        g_bytes_unref(sps); g_bytes_unref(pps);
    } else if (unit.sps || unit.pps) { recover_locked(e); goto done; }
    if (!e->sps || !e->pps || (e->waiting_idr && !unit.idr)) goto done;
    size_t cost = 0;
    if (!peel_h264_frame_cost(unit.length, g_bytes_get_size(e->sps), g_bytes_get_size(e->pps), &cost)) { fail_locked(e); goto done; }
    if (e->queue.length >= 2 || cost > PEEL_H264_MAX_AU - e->queued_bytes) recover_locked(e);
    if (e->failed || (e->waiting_idr && !unit.idr)) goto done;
    e->waiting_idr = FALSE;
    Encoded *frame = g_new0(Encoded, 1);
    frame->avcc = g_bytes_new_take(unit.avcc, unit.length); unit.avcc = NULL;
    frame->sps = g_bytes_ref(e->sps); frame->pps = g_bytes_ref(e->pps);
    frame->configuration = e->configuration; frame->idr = unit.idr; frame->cost = cost;
    frame->pts = (int64_t)GST_BUFFER_PTS(buffer);
    frame->duration = GST_BUFFER_DURATION_IS_VALID(buffer) ? (int64_t)GST_BUFFER_DURATION(buffer) : 0;
    e->queued_bytes += cost; g_queue_push_tail(&e->queue, frame); schedule_locked(e);
done:
    g_mutex_unlock(&e->lock); peel_h264_au_clear(&unit); gst_sample_unref(sample); return GST_FLOW_OK;
}
static gboolean drain_encoded(gpointer data) {
    Encoder *e = data;
    if (!is_current(e)) { g_mutex_lock(&e->lock); e->scheduled = FALSE; g_mutex_unlock(&e->lock); return G_SOURCE_REMOVE; }
    g_mutex_lock(&e->lock);
    if (e->closed) { e->scheduled = FALSE; g_mutex_unlock(&e->lock); return G_SOURCE_REMOVE; }
    if (e->failed) {
        gboolean report = !e->failure_delivered; e->failure_delivered = TRUE; e->scheduled = FALSE;
        g_mutex_unlock(&e->lock);
        gst_element_set_state(e->pipeline, GST_STATE_NULL);
        if (report && is_current(e) && e->failure) e->failure(e->source_generation, e->generation, e->user);
        return G_SOURCE_REMOVE;
    }
    Encoded *frame = g_queue_pop_head(&e->queue);
    if (!frame) { e->scheduled = FALSE; g_mutex_unlock(&e->lock); return G_SOURCE_REMOVE; }
    e->queued_bytes -= frame->cost;
    uint64_t admitted_recovery = e->recovery_serial;
    PeelEncodedFrame value = {0};
    value.source_generation = e->source_generation; value.encoder_generation = e->generation;
    value.configuration_generation = frame->configuration; value.source_id = 1;
    value.width = e->width; value.height = e->height; value.timescale = 1000000000;
    value.pts_ns = frame->pts; value.duration_ns = frame->duration; value.keyframe = frame->idr;
    value.configuration_changed = frame->configuration != e->delivered_configuration;
    value.avcc = g_bytes_get_data(frame->avcc, &value.avcc_length);
    value.sps = g_bytes_get_data(frame->sps, &value.sps_length); value.pps = g_bytes_get_data(frame->pps, &value.pps_length);
    g_mutex_unlock(&e->lock);
    /* Main-context admission and callback are synchronous: Stop cannot interleave
     * on another main task. Callback may itself Stop; e/frame retain lifetime. */
    int accepted = is_current(e) && e->deliver && e->deliver(&value, e->user);
    g_mutex_lock(&e->lock);
    if (!e->closed && !e->failed) {
        if (accepted == 1) {
            /* A producer may have overflowed/recovered while the owner copied
             * this earlier AU. Its completion cannot erase that newer reset. */
            if (e->recovery_serial == admitted_recovery) e->delivered_configuration = frame->configuration;
        } else recover_locked(e);
    }
    gboolean more = !e->closed && !e->failed && !g_queue_is_empty(&e->queue);
    if (!more) e->scheduled = FALSE;
    g_mutex_unlock(&e->lock); encoded_free(frame); return more ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}
static void encoder_shutdown(Encoder *e) {
    g_mutex_lock(&e->lock); e->closed = TRUE; clear_queue(e); e->deliver = NULL; e->failure = NULL; g_mutex_unlock(&e->lock);
    /* Never hold either lock while GStreamer waits for streaming callbacks. */
    if (e->bus_watch) { g_source_remove(e->bus_watch); e->bus_watch = 0; }
    if (e->pipeline) gst_element_set_state(e->pipeline, GST_STATE_NULL);
    if (e->sink) { GstAppSinkCallbacks empty = {0}; gst_app_sink_set_callbacks(GST_APP_SINK(e->sink), &empty, NULL, NULL); }
    g_clear_object(&e->source); g_clear_object(&e->codec); g_clear_object(&e->sink); g_clear_object(&e->pipeline);
    encoder_unref(e); /* registry/initial ownership */
}
int peel_linux_host_encoder_stop(uint64_t source, uint64_t generation) {
    if (!on_main()) return 0;
    g_mutex_lock(&registry); Encoder *e = current_encoder;
    if (!e || e->source_generation != source || e->generation != generation) { g_mutex_unlock(&registry); return 0; }
    current_encoder = NULL; g_mutex_unlock(&registry); encoder_shutdown(e); return 1;
}
static gboolean seed_latest(Encoder *e, gboolean initial) {
    /* Request keyframe outside queue/registry locks: the video encoder may
     * synchronously send events while its streaming thread owns codec locks. */
    g_mutex_lock(&e->lock);
    gboolean force = !initial && !e->closed && !e->failed;
    GstElement *codec = force ? gst_object_ref(e->codec) : NULL;
    if (force) e->request_keyframe = FALSE;
    g_mutex_unlock(&e->lock);
    if (codec) { force_keyframe(codec); gst_object_unref(codec); }
    g_mutex_lock(&registry);
    if (current_encoder != e || !capture.active || capture.source_generation != e->source_generation ||
        capture.width != e->width || capture.height != e->height || !latest_sample ||
        latest_generation != e->source_generation || latest_width != e->width || latest_height != e->height) {
        g_mutex_unlock(&registry); return FALSE;
    }
    GstVideoInfo info; GstBuffer *buffer = gst_sample_get_buffer(latest_sample);
    gboolean valid = buffer && gst_video_info_from_caps(&info, gst_sample_get_caps(latest_sample)) &&
        GST_VIDEO_INFO_FORMAT(&info) == GST_VIDEO_FORMAT_BGRA && info.width == (int)e->width && info.height == (int)e->height &&
        gst_buffer_get_size(buffer) >= info.size && gst_buffer_get_size(buffer) <= 134217728 &&
        GST_BUFFER_PTS_IS_VALID(buffer) && GST_BUFFER_PTS(buffer) <= INT64_MAX;
    g_mutex_lock(&e->lock);
    if (e->closed || e->failed || !valid) { g_mutex_unlock(&e->lock); g_mutex_unlock(&registry); return FALSE; }
    /* A current real capture may already have fed the newly started codec.
     * Do not enqueue a duplicate initial seed or an older timestamp. */
    if (initial && e->last_input_pts != GST_CLOCK_TIME_NONE) {
        g_mutex_unlock(&e->lock); g_mutex_unlock(&registry); return TRUE;
    }
    if (e->last_input_pts != GST_CLOCK_TIME_NONE && GST_BUFFER_PTS(buffer) < e->last_input_pts) {
        g_mutex_unlock(&e->lock); g_mutex_unlock(&registry); return FALSE;
    }
    e->last_input_pts = GST_BUFFER_PTS(buffer);
    /* Both locks cover ONLY immediate nonblocking appsrc enqueue, not codec work.
     * A new-size pending sample cannot replace this latest sample at admission. */
    gboolean ok = gst_app_src_push_sample(GST_APP_SRC(e->source), latest_sample) == GST_FLOW_OK;
    if (!ok) fail_locked(e);
    g_mutex_unlock(&e->lock); g_mutex_unlock(&registry); return ok;
}
int peel_linux_host_encoder_request_keyframe(uint64_t source, uint64_t generation) {
    if (!on_main()) return 0;
    g_mutex_lock(&registry); Encoder *e = current_encoder;
    if (!e || e->source_generation != source || e->generation != generation) { g_mutex_unlock(&registry); return 0; }
    encoder_ref(e); g_mutex_unlock(&registry);
    g_mutex_lock(&e->lock); gboolean ok = !e->closed && !e->failed;
    if (ok) recover_locked(e);
    g_mutex_unlock(&e->lock);
    if (ok) ok = seed_latest(e, FALSE);
    encoder_unref(e); return ok;
}
uint64_t peel_linux_host_encoder_start(uint64_t source, uint32_t bitrate, uint32_t gop,
    PeelEncodedSink sink, PeelEncoderFailed failure, void *user) {
    if (!on_main() || !sink || bitrate < 64000 || bitrate > 100000000 || !gop || gop > 120 || !peel_linux_h264_encoder_available()) return 0;
    g_mutex_lock(&registry); PeelCaptureInfo value = capture; Encoder *old = current_encoder;
    if (!value.active || value.source_generation != source || !value.width || !value.height ||
        !latest_sample || latest_generation != source || latest_width != value.width || latest_height != value.height) { g_mutex_unlock(&registry); return 0; }
    current_encoder = NULL; g_mutex_unlock(&registry);
    if (old) encoder_shutdown(old);
    Encoder *e = g_new0(Encoder, 1); g_atomic_ref_count_init(&e->refs); g_mutex_init(&e->lock); g_queue_init(&e->queue);
    e->source_generation = source; e->width = value.width; e->height = value.height;
    e->last_input_pts = e->last_output_pts = GST_CLOCK_TIME_NONE; e->waiting_idr = TRUE;
    e->deliver = sink; e->failure = failure; e->user = user;
    GError *error = NULL;
    /* OpenH264 already returns one byte-stream AU with real SPS/PPS on IDR.
     * A following h264parse would erase a repeated real PTS in GstBaseParse.
     * Keep its direct PTS/caps and validate the complete AU at the sink;
     * never replace a missing timestamp or infer a keyframe from an event. */
    e->pipeline = gst_parse_launch("appsrc name=raw is-live=true format=time block=false max-buffers=1 max-bytes=134217728 leaky-type=downstream ! videoconvert ! video/x-raw,format=I420 ! openh264enc name=codec usage-type=screen rate-control=bitrate complexity=low enable-frame-skip=true multi-thread=1 ! video/x-h264,stream-format=byte-stream,alignment=au,profile=constrained-baseline ! appsink name=encoded sync=false max-buffers=2 drop=false enable-last-sample=false", &error);
    if (!e->pipeline || error) { g_clear_error(&error); encoder_shutdown(e); return 0; }
    e->source = gst_bin_get_by_name(GST_BIN(e->pipeline), "raw"); e->codec = gst_bin_get_by_name(GST_BIN(e->pipeline), "codec"); e->sink = gst_bin_get_by_name(GST_BIN(e->pipeline), "encoded");
    if (!e->source || !e->codec || !e->sink) { encoder_shutdown(e); return 0; }
    g_object_set(e->codec, "bitrate", bitrate, "max-bitrate", bitrate, "gop-size", gop, NULL);
    GstAppSinkCallbacks callbacks = { .new_sample = encoded_sample };
    gst_app_sink_set_callbacks(GST_APP_SINK(e->sink), &callbacks, encoder_ref(e), (GDestroyNotify)encoder_unref);
    GstBus *bus = gst_element_get_bus(e->pipeline);
    e->bus_watch = gst_bus_add_watch_full(bus, G_PRIORITY_DEFAULT, encoder_bus, encoder_ref(e), (GDestroyNotify)encoder_unref); gst_object_unref(bus);
    g_mutex_lock(&registry);
    if (!capture.active || capture.source_generation != source || capture.width != e->width || capture.height != e->height ||
        !latest_sample || latest_generation != source || latest_width != e->width || latest_height != e->height || next_encoder_generation == UINT64_MAX) {
        g_mutex_unlock(&registry); encoder_shutdown(e); return 0;
    }
    e->generation = ++next_encoder_generation; current_encoder = e; g_mutex_unlock(&registry);
    if (gst_element_set_state(e->pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        peel_linux_host_encoder_stop(source, e->generation); return 0;
    }
    if (!seed_latest(e, TRUE)) { peel_linux_host_encoder_stop(source, e->generation); return 0; }
    return e->generation; /* setup/one actual-sample seed admitted, not output proof */
}
void peel_encoder_capture_open(uint64_t generation, uint32_t kind) {
    g_return_if_fail(on_main());
    g_mutex_lock(&registry); Encoder *retired = current_encoder; current_encoder = NULL;
    GstSample *old_sample = latest_sample; latest_sample = NULL; latest_generation = 0; latest_width = latest_height = 0;
    capture = (PeelCaptureInfo){ .source_generation = generation, .source_id = 1, .source_kind = kind };
    capture_pending = FALSE; memset(&pending_capture, 0, sizeof(pending_capture));
    g_mutex_unlock(&registry);
    if (retired) encoder_shutdown(retired);
    if (old_sample) gst_sample_unref(old_sample);
    notify_capture_now();
}
void peel_encoder_capture_close(uint64_t generation) {
    gboolean acquired = FALSE;
    if (!on_main()) { acquired = g_main_context_acquire(g_main_context_default()); g_return_if_fail(acquired); }
    g_mutex_lock(&registry);
    if (capture.source_generation != generation) {
        g_mutex_unlock(&registry); if (acquired) g_main_context_release(g_main_context_default()); return;
    }
    Encoder *e = current_encoder; current_encoder = NULL; memset(&capture, 0, sizeof(capture));
    GstSample *old_sample = latest_sample; latest_sample = NULL; latest_generation = 0; latest_width = latest_height = 0;
    capture_pending = FALSE; memset(&pending_capture, 0, sizeof(pending_capture));
    g_mutex_unlock(&registry);
    if (e) encoder_shutdown(e);
    if (old_sample) gst_sample_unref(old_sample);
    notify_capture_now(); /* managed adapter retires exact source synchronously */
    if (acquired) g_main_context_release(g_main_context_default());
}
void peel_encoder_capture_sample(uint64_t generation, GstSample *sample) {
    GstVideoInfo info; GstBuffer *buffer = sample ? gst_sample_get_buffer(sample) : NULL;
    if (!buffer || !gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) ||
        GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_BGRA || info.width < 1 || info.height < 1 ||
        info.width > 8192 || info.height > 8192 || (uint64_t)info.width * info.height > 33554432 ||
        gst_buffer_get_size(buffer) < info.size || gst_buffer_get_size(buffer) > 134217728) return;
    g_mutex_lock(&registry);
    if (!generation || capture.source_generation != generation) { g_mutex_unlock(&registry); return; }
    GstSample *previous = latest_sample; latest_sample = gst_sample_ref(sample);
    latest_generation = generation; latest_width = (uint32_t)info.width; latest_height = (uint32_t)info.height;
    if (!capture.active || capture.width != (uint32_t)info.width || capture.height != (uint32_t)info.height || capture_pending) {
        pending_capture = capture; pending_capture.active = TRUE;
        pending_capture.width = (uint32_t)info.width; pending_capture.height = (uint32_t)info.height;
        capture_pending = TRUE; queue_capture_notice_locked();
    }
    Encoder *e = current_encoder && current_encoder->source_generation == generation ? encoder_ref(current_encoder) : NULL;
    g_mutex_unlock(&registry);
    if (previous) gst_sample_unref(previous);
    if (!e) return;
    g_mutex_lock(&e->lock);
    if (e->closed || e->failed) { g_mutex_unlock(&e->lock); encoder_unref(e); return; }
    if (info.width != (int)e->width || info.height != (int)e->height) {
        /* New-size raw samples cannot enter the old codec. Main-context capture
         * publication retires it before notifying the owner of changed caps. */
        g_mutex_unlock(&e->lock); encoder_unref(e); return;
    }
    if (!GST_BUFFER_PTS_IS_VALID(buffer) || GST_BUFFER_PTS(buffer) > INT64_MAX ||
        (e->last_input_pts != GST_CLOCK_TIME_NONE && GST_BUFFER_PTS(buffer) < e->last_input_pts)) {
        fail_locked(e); g_mutex_unlock(&e->lock); encoder_unref(e); return;
    }
    /* Start may have seeded this very sample while the capture callback was
     * between registry and codec admission. Do not enqueue the same PTS twice;
     * explicit keyframe replay is admitted only by seed_latest. */
    if (e->last_input_pts == GST_BUFFER_PTS(buffer)) {
        g_mutex_unlock(&e->lock); encoder_unref(e); return;
    }
    e->last_input_pts = GST_BUFFER_PTS(buffer);
    gboolean force = e->request_keyframe; e->request_keyframe = FALSE;
    GstElement *codec = force ? gst_object_ref(e->codec) : NULL;
    g_mutex_unlock(&e->lock);
    if (codec) { force_keyframe(codec); gst_object_unref(codec); }
    g_mutex_lock(&e->lock);
    if (!e->closed && !e->failed && gst_app_src_push_sample(GST_APP_SRC(e->source), sample) != GST_FLOW_OK) fail_locked(e);
    g_mutex_unlock(&e->lock); encoder_unref(e);
}
