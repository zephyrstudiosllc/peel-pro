#include "internal.h"
#include <string.h>

/* Receiver playback sink for the streamed source's PEAU v1 downlink PCM. The
 * managed AudioPacketReader validated header, direction, rate, channels and
 * sample size; this boundary independently accepts only one fixed 20 ms
 * S16LE/48 kHz/stereo payload per push. No GTK, no default-context bus watch:
 * a sync handler records ERROR/EOS and drops (unrefs) every message so the bus
 * cannot grow. Output selection: autoaudiosink when installed (gst-plugins-good),
 * and the sink it actually selected must be a real audio sink; its documented
 * no-usable-sink fallback is a fakesink at READY (plus a WARNING), which reads as
 * no output, never as playback. When autoaudiosink is NOT installed, only an
 * exact allowlist is tried, in fixed order (pipewiresink, then alsasink), and each
 * must also have a Sink class and a sink pad template that can accept raw audio.
 * Nothing else (fakesink, video or other sinks, look-alike names without audio
 * caps) is accepted. No device, route, volume or permission is chosen or changed:
 * each backend opens its normal default output. Live appsrc timestamps arrival;
 * queued input is bounded to 200 ms and excess packets are dropped rather than
 * blocking the network reader. */
#define PEEL_AUDIO_RATE 48000
#define PEEL_AUDIO_CHANNELS 2
#define PEEL_AUDIO_FRAMES 960
#define PEEL_AUDIO_PACKET_BYTES (PEEL_AUDIO_FRAMES * PEEL_AUDIO_CHANNELS * 2)
#define PEEL_AUDIO_MAX_QUEUED_BYTES (PEEL_AUDIO_PACKET_BYTES * 10)
#define PEEL_AUDIO_JITTER_NS (40 * GST_MSECOND)

typedef struct {
    GMutex lock;
    uint64_t generation;
    gboolean closed;
    gint failed; /* atomic; set from the streaming thread's bus sync handler */
    GstElement *pipeline, *source;
} PeelAudio;

static char *test_sink; /* tests only, set before any audio handle exists */
void peel_audio_test_sink(const char *description) { g_free(test_sink); test_sink = g_strdup(description); }

/* Exact fallbacks used only when autoaudiosink is absent, in this order. */
static const char *const fallback_outputs[] = { "pipewiresink", "alsasink" };
#define PEEL_AUDIO_MAX_CANDIDATES G_N_ELEMENTS(fallback_outputs)

static GstElement *make_test_sink(void) {
    GError *error = NULL;
    GstElement *bin = gst_parse_bin_from_description(test_sink, TRUE, &error);
    if (error) { g_clear_error(&error); if (bin) gst_object_unref(bin); return NULL; }
    return bin;
}

static gboolean factory_present(const char *name) {
    GstElementFactory *factory = gst_element_factory_find(name);
    if (!factory) return FALSE;
    gst_object_unref(factory); return TRUE;
}

/* Registry metadata only: some sink pad template can intersect audio/x-raw. ANY
 * caps intersect too, which is why this is never sufficient on its own. */
gboolean peel_audio_factory_accepts_pcm(GstElementFactory *factory) {
    if (!factory) return FALSE;
    GstCaps *pcm = gst_caps_new_empty_simple("audio/x-raw");
    gboolean accepts = FALSE;
    for (const GList *item = gst_element_factory_get_static_pad_templates(factory); item && !accepts; item = item->next) {
        GstStaticPadTemplate *pad = item->data;
        if (pad->direction != GST_PAD_SINK) continue;
        GstCaps *caps = gst_static_pad_template_get_caps(pad);
        accepts = caps && gst_caps_can_intersect(caps, pcm);
        if (caps) gst_caps_unref(caps);
    }
    gst_caps_unref(pcm);
    return accepts;
}

/* Exact allowlisted fallback name AND a Sink class AND a raw-audio sink pad. A
 * name alone, a class alone or caps alone never qualifies. */
gboolean peel_audio_factory_qualified(GstElementFactory *factory) {
    if (!factory) return FALSE;
    const char *name = gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory));
    gboolean known = FALSE;
    for (guint i = 0; i < G_N_ELEMENTS(fallback_outputs); i++) if (name && !strcmp(name, fallback_outputs[i])) known = TRUE;
    const char *klass = gst_element_factory_get_metadata(factory, GST_ELEMENT_METADATA_KLASS);
    return known && klass && strstr(klass, "Sink") && peel_audio_factory_accepts_pcm(factory);
}

/* Installed qualified fallbacks in fixed order; registry metadata only, nothing opened. */
static guint fallback_candidates(const char **names) {
    guint count = 0;
    for (guint i = 0; i < G_N_ELEMENTS(fallback_outputs); i++) {
        GstElementFactory *factory = gst_element_factory_find(fallback_outputs[i]);
        if (factory && peel_audio_factory_qualified(factory)) names[count++] = fallback_outputs[i];
        if (factory) gst_object_unref(factory);
    }
    return count;
}

/* Production order: autoaudiosink alone when installed (its fake fallback is then
 * rejected, never bypassed); otherwise the qualified fallbacks. */
static guint output_candidates(const char **names) {
    if (factory_present("autoaudiosink")) { names[0] = "autoaudiosink"; return 1; }
    return fallback_candidates(names);
}

const char *peel_audio_fallback_choice(void) {
    const char *names[PEEL_AUDIO_MAX_CANDIDATES];
    return fallback_candidates(names) ? names[0] : NULL;
}

const char *peel_audio_output_choice(void) {
    const char *names[PEEL_AUDIO_MAX_CANDIDATES];
    return output_candidates(names) ? names[0] : NULL;
}

/* Walks the subtree autoaudiosink selected at READY. Converters are ignored; every
 * element whose factory class is a Sink must be a real audio sink. A fakesink,
 * a non-audio sink, a factory-less sink, an iterator resync or excessive nesting
 * fails closed. */
static void classify_sinks(GstElement *element, int depth, int *real, int *fake) {
    if (depth > 8) { (*fake)++; return; }
    if (GST_IS_BIN(element)) {
        GstIterator *children = gst_bin_iterate_elements(GST_BIN(element));
        GValue item = G_VALUE_INIT; gboolean done = FALSE;
        while (!done) {
            switch (gst_iterator_next(children, &item)) {
            case GST_ITERATOR_OK: classify_sinks(g_value_get_object(&item), depth + 1, real, fake); g_value_reset(&item); break;
            case GST_ITERATOR_DONE: done = TRUE; break;
            default: (*fake)++; done = TRUE; break; /* RESYNC/ERROR: no trustworthy answer */
            }
        }
        g_value_unset(&item); gst_iterator_free(children); return;
    }
    GstElementFactory *factory = gst_element_get_factory(element);
    const char *klass = factory ? gst_element_factory_get_metadata(factory, GST_ELEMENT_METADATA_KLASS) : NULL;
    if (!factory) { if (GST_OBJECT_FLAG_IS_SET(element, GST_ELEMENT_FLAG_SINK)) (*fake)++; return; }
    if (!klass || !strstr(klass, "Sink")) return;
    if (!strcmp(gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory)), "fakesink")) (*fake)++;
    else if (strstr(klass, "Audio") || peel_audio_factory_qualified(factory)) (*real)++;
    else (*fake)++;
}
gboolean peel_audio_sink_is_real(GstElement *sink) {
    int real = 0, fake = 0;
    if (!sink) return FALSE;
    classify_sinks(sink, 0, &real, &fake);
    return real > 0 && fake == 0;
}

/* NULL->READY opens the backend's normal default output exactly as autoaudiosink's
 * own probing does; READY alone is not proof, so the selection is inspected too. */
static gboolean output_ready(GstElement *sink, gboolean substituted) {
    if (!sink) return FALSE;
    gst_object_ref_sink(sink);
    gboolean ready = gst_element_set_state(sink, GST_STATE_READY) != GST_STATE_CHANGE_FAILURE &&
        (substituted || peel_audio_sink_is_real(sink)); /* substituted sinks are TEST ONLY */
    gst_element_set_state(sink, GST_STATE_NULL); gst_object_unref(sink);
    return ready;
}

int peel_linux_audio_available(void) {
    if (!gst_is_initialized() || !factory_present("appsrc") || !factory_present("audioconvert") || !factory_present("audioresample")) return 0;
    if (test_sink) return output_ready(make_test_sink(), TRUE) ? 1 : 0;
    const char *names[PEEL_AUDIO_MAX_CANDIDATES];
    guint count = output_candidates(names);
    for (guint i = 0; i < count; i++) if (output_ready(gst_element_factory_make(names[i], "output"), FALSE)) return 1;
    return 0;
}

static GstBusSyncReply audio_bus(GstBus *bus, GstMessage *message, gpointer data) {
    (void)bus; PeelAudio *a = data;
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR || GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) g_atomic_int_set(&a->failed, 1);
    gst_message_unref(message); /* GST_BUS_DROP transfers the message to this handler */
    return GST_BUS_DROP;
}

static void audio_release(PeelAudio *a) {
    if (!a->pipeline) return;
    gst_element_set_state(a->pipeline, GST_STATE_NULL);
    GstBus *bus = gst_element_get_bus(a->pipeline); gst_bus_set_sync_handler(bus, NULL, NULL, NULL); gst_object_unref(bus);
    g_clear_object(&a->source); gst_object_unref(a->pipeline); a->pipeline = NULL;
}

/* Builds and starts one pipeline on this sink; on any failure leaves a released. */
static gboolean audio_open(PeelAudio *a, GstElement *sink, gboolean substituted) {
    GstElement *source = gst_element_factory_make("appsrc", "pcm"), *convert = gst_element_factory_make("audioconvert", NULL),
        *resample = gst_element_factory_make("audioresample", NULL);
    a->pipeline = gst_pipeline_new("peel-receiver-audio");
    g_atomic_int_set(&a->failed, 0);
    if (!a->pipeline || !source || !convert || !resample || !sink) {
        if (source) gst_object_unref(gst_object_ref_sink(source));
        if (convert) gst_object_unref(gst_object_ref_sink(convert));
        if (resample) gst_object_unref(gst_object_ref_sink(resample));
        if (sink) gst_object_unref(gst_object_ref_sink(sink));
        if (a->pipeline) { gst_object_unref(a->pipeline); a->pipeline = NULL; }
        return FALSE;
    }
    gst_bin_add_many(GST_BIN(a->pipeline), source, convert, resample, sink, NULL);
    a->source = gst_object_ref(source);
    GstCaps *caps = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, "S16LE", "rate", G_TYPE_INT, PEEL_AUDIO_RATE,
        "channels", G_TYPE_INT, PEEL_AUDIO_CHANNELS, "layout", G_TYPE_STRING, "interleaved", NULL);
    g_object_set(source, "caps", caps, "is-live", TRUE, "format", GST_FORMAT_TIME, "do-timestamp", TRUE, "block", FALSE,
        "max-bytes", (guint64)PEEL_AUDIO_MAX_QUEUED_BYTES, "min-latency", (gint64)PEEL_AUDIO_JITTER_NS, NULL);
    gst_caps_unref(caps);
    GstBus *bus = gst_element_get_bus(a->pipeline); gst_bus_set_sync_handler(bus, audio_bus, a, NULL); gst_object_unref(bus);
    /* PLAYING runs the sink's NULL->READY synchronously (autoaudiosink selects then);
     * the selected output must still classify as real. */
    if (!gst_element_link_many(source, convert, resample, sink, NULL) ||
        gst_element_set_state(a->pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE || g_atomic_int_get(&a->failed) ||
        (!substituted && !peel_audio_sink_is_real(sink)) || !peel_receiver_current(a->generation)) {
        audio_release(a); return FALSE;
    }
    return TRUE;
}

void *peel_linux_audio_new(uint64_t generation) {
    if (!gst_is_initialized() || !peel_receiver_current(generation)) return NULL;
    PeelAudio *a = g_new0(PeelAudio, 1); g_mutex_init(&a->lock); a->generation = generation;
    gboolean opened = FALSE;
    if (test_sink) opened = audio_open(a, make_test_sink(), TRUE);
    else {
        /* Same fixed order as the probe; the first candidate that really starts wins. */
        const char *names[PEEL_AUDIO_MAX_CANDIDATES];
        guint count = output_candidates(names);
        for (guint i = 0; i < count && !opened && peel_receiver_current(generation); i++)
            opened = audio_open(a, gst_element_factory_make(names[i], "output"), FALSE);
    }
    if (!opened) { g_mutex_clear(&a->lock); g_free(a); return NULL; }
    return a;
}

int peel_linux_audio_push(void *handle, const uint8_t *pcm, size_t length) {
    PeelAudio *a = handle;
    if (!a || !pcm || length != PEEL_AUDIO_PACKET_BYTES) return -1;
    g_mutex_lock(&a->lock);
    if (a->closed || !a->source || g_atomic_int_get(&a->failed) || !peel_receiver_current(a->generation)) { g_mutex_unlock(&a->lock); return -1; }
    if (gst_app_src_get_current_level_bytes(GST_APP_SRC(a->source)) + length > PEEL_AUDIO_MAX_QUEUED_BYTES) { g_mutex_unlock(&a->lock); return 0; }
    GstBuffer *buffer = gst_buffer_new_memdup(pcm, length);
    GST_BUFFER_DURATION(buffer) = gst_util_uint64_scale_int(PEEL_AUDIO_FRAMES, GST_SECOND, PEEL_AUDIO_RATE);
    gboolean ok = gst_app_src_push_buffer(GST_APP_SRC(a->source), buffer) == GST_FLOW_OK;
    if (!ok) g_atomic_int_set(&a->failed, 1);
    g_mutex_unlock(&a->lock);
    return ok ? 1 : -1;
}

void peel_linux_audio_free(void *handle) {
    PeelAudio *a = handle; if (!a) return;
    g_mutex_lock(&a->lock); a->closed = TRUE; g_mutex_unlock(&a->lock);
    audio_release(a); g_mutex_clear(&a->lock); g_free(a);
}
