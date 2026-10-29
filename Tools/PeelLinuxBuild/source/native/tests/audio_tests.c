#include "internal.h"
#include <stdio.h>
#include <string.h>

/* Receiver PCM sink boundary checks with substituted non-device sinks, the
 * production autoaudiosink fake-fallback rejection (when that plugin is
 * installed) and the missing-autoaudiosink backend selection, using only
 * process-local registry rank/feature seams and test-registered elements. No
 * GTK initialization, display, audio server, socket, real source audio, and no
 * installed real sink is ever set to READY. Proves input validation, the bounded
 * non-blocking queue, receiver-generation fences, error latching,
 * teardown/recreate, fake/non-audio rejection and deterministic qualified backend
 * choice; not audible playback, device opening or latency. */
static unsigned assertions;
#define REQUIRE(x) do { assertions++; if (!(x)) { fprintf(stderr, "Assertion failed at %s:%d: %s\n", __FILE__, __LINE__, #x); return 1; } } while (0)
#define PACKET 3840

typedef struct { GstPluginFeature *feature; guint rank; } Demoted;

static gboolean audio_sink_class(GstElementFactory *factory) {
    const char *klass = gst_element_factory_get_metadata(factory, GST_ELEMENT_METADATA_KLASS);
    return klass && strstr(klass, "Sink") && strstr(klass, "Audio");
}

/* Process-local registry change only: every autopluggable audio sink drops below
 * GST_RANK_MARGINAL, so the real autoaudiosink has no candidate and must take its
 * no-usable-sink path. No device, server, routing or system setting is touched. */
static GArray *demote_audio_sinks(void) {
    GArray *demoted = g_array_new(FALSE, FALSE, sizeof(Demoted));
    GList *features = gst_registry_get_feature_list(gst_registry_get(), GST_TYPE_ELEMENT_FACTORY);
    for (GList *item = features; item; item = item->next) {
        GstPluginFeature *feature = item->data;
        guint rank = gst_plugin_feature_get_rank(feature);
        if (rank < GST_RANK_MARGINAL || !audio_sink_class(GST_ELEMENT_FACTORY(feature))) continue;
        Demoted entry = { gst_object_ref(feature), rank };
        g_array_append_val(demoted, entry);
        gst_plugin_feature_set_rank(feature, GST_RANK_NONE);
    }
    gst_plugin_feature_list_free(features);
    return demoted;
}

static void restore_ranks(GArray *demoted) {
    for (guint i = 0; i < demoted->len; i++) {
        Demoted *entry = &g_array_index(demoted, Demoted, i);
        gst_plugin_feature_set_rank(entry->feature, entry->rank); gst_object_unref(entry->feature);
    }
    g_array_free(demoted, TRUE);
}

/* An installed real audio sink factory, instantiated only (never set to READY). */
static GstElement *real_sink_element(void) {
    GstElement *element = NULL;
    GList *features = gst_registry_get_feature_list(gst_registry_get(), GST_TYPE_ELEMENT_FACTORY);
    for (GList *item = features; item && !element; item = item->next) {
        GstPluginFeature *feature = item->data;
        const char *name = gst_plugin_feature_get_name(feature);
        if (!audio_sink_class(GST_ELEMENT_FACTORY(feature)) || g_str_has_prefix(name, "auto") || !strcmp(name, "fakesink")) continue;
        element = gst_element_factory_create(GST_ELEMENT_FACTORY(feature), NULL);
        if (element && GST_IS_BIN(element)) { gst_object_unref(gst_object_ref_sink(element)); element = NULL; }
    }
    gst_plugin_feature_list_free(features);
    return element;
}

/* Test-only element types registered in this process: a video-only sink and a raw
 * audio sink. Neither is an allowlisted backend name; one can impersonate the
 * pipewiresink name only while the real factory is detached from the registry. */
typedef GstElement PeelTestVideoSink; typedef GstElementClass PeelTestVideoSinkClass;
typedef GstElement PeelTestAudioSink; typedef GstElementClass PeelTestAudioSinkClass;
G_DEFINE_TYPE(PeelTestVideoSink, peel_test_video_sink, GST_TYPE_ELEMENT)
G_DEFINE_TYPE(PeelTestAudioSink, peel_test_audio_sink, GST_TYPE_ELEMENT)
static GstStaticPadTemplate video_only = GST_STATIC_PAD_TEMPLATE("sink", GST_PAD_SINK, GST_PAD_ALWAYS, GST_STATIC_CAPS("video/x-raw"));
static GstStaticPadTemplate raw_audio = GST_STATIC_PAD_TEMPLATE("sink", GST_PAD_SINK, GST_PAD_ALWAYS, GST_STATIC_CAPS("audio/x-raw"));
static void peel_test_video_sink_class_init(PeelTestVideoSinkClass *klass) {
    gst_element_class_set_static_metadata(klass, "Peel test video sink", "Sink/Video", "Test fixture only", "Peel");
    gst_element_class_add_static_pad_template(klass, &video_only);
}
static void peel_test_video_sink_init(PeelTestVideoSink *self) { GST_OBJECT_FLAG_SET(self, GST_ELEMENT_FLAG_SINK); }
static void peel_test_audio_sink_class_init(PeelTestAudioSinkClass *klass) {
    gst_element_class_set_static_metadata(klass, "Peel test audio sink", "Sink/Audio", "Test fixture only", "Peel");
    gst_element_class_add_static_pad_template(klass, &raw_audio);
}
static void peel_test_audio_sink_init(PeelTestAudioSink *self) { GST_OBJECT_FLAG_SET(self, GST_ELEMENT_FLAG_SINK); }
/* Separate type so its class's factory is only ever the impostor registration. */
typedef GstElement PeelTestImpostorSink; typedef GstElementClass PeelTestImpostorSinkClass;
G_DEFINE_TYPE(PeelTestImpostorSink, peel_test_impostor_sink, GST_TYPE_ELEMENT)
static void peel_test_impostor_sink_class_init(PeelTestImpostorSinkClass *klass) {
    gst_element_class_set_static_metadata(klass, "Peel test video-only impostor", "Sink/Video", "Test fixture only", "Peel");
    gst_element_class_add_static_pad_template(klass, &video_only);
}
static void peel_test_impostor_sink_init(PeelTestImpostorSink *self) { GST_OBJECT_FLAG_SET(self, GST_ELEMENT_FLAG_SINK); }

/* Process-local seam: detach an installed factory from the in-memory registry
 * (returned with our reference) and re-attach it later. No file or cache write. */
static GstPluginFeature *detach_feature(const char *name) {
    GstPluginFeature *feature = gst_registry_lookup_feature(gst_registry_get(), name);
    if (feature) gst_registry_remove_feature(gst_registry_get(), feature);
    return feature;
}
static void attach_feature(GstPluginFeature *feature) {
    if (!feature) return;
    gst_registry_add_feature(gst_registry_get(), feature); gst_object_unref(feature);
}
static gboolean installed_qualified(const char *name) {
    GstElementFactory *factory = gst_element_factory_find(name);
    gboolean qualified = factory && peel_audio_factory_qualified(factory);
    if (factory) gst_object_unref(factory);
    return qualified;
}
static gboolean factory_flag(const char *name, gboolean (*check)(GstElementFactory *)) {
    GstElementFactory *factory = gst_element_factory_find(name);
    gboolean result = factory && check(factory);
    if (factory) gst_object_unref(factory);
    return result;
}

static GstElement *bin_of(GstElement *first, GstElement *second) {
    GstElement *bin = gst_bin_new(NULL);
    if (first) gst_bin_add(GST_BIN(bin), first);
    if (second) gst_bin_add(GST_BIN(bin), second);
    return gst_object_ref_sink(bin);
}

int main(void) {
    gst_init(NULL, NULL);
    uint8_t pcm[PACKET]; memset(pcm, 0, sizeof pcm);

    /* Missing output is reported unavailable and opens nothing. */
    peel_audio_test_sink("peel-no-such-output-element");
    REQUIRE(peel_linux_audio_available() == 0);
    peel_linux_receiver_generation(7);
    REQUIRE(peel_linux_audio_new(7) == NULL);

    /* A slow sink (50 ms per packet) never blocks the caller; the queue stays bounded. */
    peel_audio_test_sink("identity sleep-time=50000 ! fakesink sync=false");
    REQUIRE(peel_linux_audio_available() == 1);
    REQUIRE(peel_linux_audio_new(6) == NULL); /* stale receiver generation */
    void *audio = peel_linux_audio_new(7);
    REQUIRE(audio != NULL);
    REQUIRE(peel_linux_audio_push(audio, pcm, PACKET - 1) == -1);
    REQUIRE(peel_linux_audio_push(audio, pcm, PACKET + 1) == -1);
    REQUIRE(peel_linux_audio_push(audio, NULL, PACKET) == -1);
    REQUIRE(peel_linux_audio_push(NULL, pcm, PACKET) == -1);
    gint64 start = g_get_monotonic_time();
    int queued = 0, dropped = 0;
    for (int i = 0; i < 60; i++) {
        int result = peel_linux_audio_push(audio, pcm, PACKET);
        REQUIRE(result == 0 || result == 1);
        if (result == 1) queued++; else dropped++;
    }
    REQUIRE(g_get_monotonic_time() - start < G_USEC_PER_SEC);
    REQUIRE(queued >= 1 && queued <= 14 && dropped >= 46);

    /* Replacing the receiver generation fences the old handle immediately. */
    peel_linux_receiver_generation(8);
    REQUIRE(peel_linux_audio_push(audio, pcm, PACKET) == -1);
    start = g_get_monotonic_time();
    peel_linux_audio_free(audio); /* drops queued PCM; must not wait for the slow sink to drain */
    REQUIRE(g_get_monotonic_time() - start < 2 * G_USEC_PER_SEC);

    /* Recreate on the current generation. */
    audio = peel_linux_audio_new(8);
    REQUIRE(audio != NULL);
    REQUIRE(peel_linux_audio_push(audio, pcm, PACKET) == 1);
    peel_linux_audio_free(audio);

    /* A pipeline error latches failure; the owner then frees and may recreate. */
    peel_audio_test_sink("identity error-after=1 ! fakesink sync=false");
    audio = peel_linux_audio_new(8);
    REQUIRE(audio != NULL);
    gboolean failed = FALSE;
    for (int i = 0; i < 200 && !failed; i++) {
        int result = peel_linux_audio_push(audio, pcm, PACKET);
        REQUIRE(result >= -1 && result <= 1);
        failed = result == -1;
        if (!failed) g_usleep(10000);
    }
    REQUIRE(failed);
    REQUIRE(peel_linux_audio_push(audio, pcm, PACKET) == -1);
    peel_linux_audio_free(audio);
    peel_linux_audio_free(NULL);

    /* Production selection check: only a real audio sink counts as output. */
    peel_audio_test_sink(NULL);
    GstElement *checked = bin_of(gst_element_factory_make("fakesink", NULL), NULL);
    REQUIRE(!peel_audio_sink_is_real(checked)); gst_object_unref(checked);
    checked = bin_of(NULL, NULL); REQUIRE(!peel_audio_sink_is_real(checked)); gst_object_unref(checked);
    checked = bin_of(gst_element_factory_make("identity", NULL), NULL); REQUIRE(!peel_audio_sink_is_real(checked)); gst_object_unref(checked);
    checked = gst_object_ref_sink(gst_element_factory_make("fakesink", NULL)); REQUIRE(!peel_audio_sink_is_real(checked)); gst_object_unref(checked);
    REQUIRE(!peel_audio_sink_is_real(NULL));
    GstElement *real = real_sink_element();
    if (real) {
        checked = bin_of(real, gst_element_factory_make("audioconvert", NULL));
        REQUIRE(peel_audio_sink_is_real(checked)); gst_object_unref(checked);
        checked = bin_of(real_sink_element(), gst_element_factory_make("fakesink", NULL));
        REQUIRE(!peel_audio_sink_is_real(checked)); gst_object_unref(checked);
    } else printf("No real audio sink factory installed; positive classification not exercised.\n");

    /* The actual autoaudiosink with no usable candidate, when that plugin is installed:
     * upstream falls back to a fakesink at READY (with a WARNING) or fails READY.
     * Either way production must report no output and refuse to open playback. */
    GstPluginFeature *automatic_feature = gst_registry_lookup_feature(gst_registry_get(), "autoaudiosink");
    if (automatic_feature) {
        GArray *demoted = demote_audio_sinks();
        GstPluginFeature *pipewire = detach_feature("pipewiresink"), *alsa = detach_feature("alsasink"); /* explicit fallbacks are never consulted while autoaudiosink exists, but keep this device-free regardless */
        REQUIRE(!strcmp(peel_audio_output_choice(), "autoaudiosink"));
        GstElement *automatic = gst_element_factory_make("autoaudiosink", NULL);
        REQUIRE(automatic != NULL);
        gst_object_ref_sink(automatic);
        gboolean fallback_ready = gst_element_set_state(automatic, GST_STATE_READY) != GST_STATE_CHANGE_FAILURE;
        if (fallback_ready) REQUIRE(!peel_audio_sink_is_real(automatic));
        gst_element_set_state(automatic, GST_STATE_NULL); gst_object_unref(automatic);
        REQUIRE(peel_linux_audio_available() == 0);
        peel_linux_receiver_generation(9);
        REQUIRE(peel_linux_audio_new(9) == NULL);
        attach_feature(alsa); attach_feature(pipewire);
        restore_ranks(demoted);
        printf("autoaudiosink without candidates %s; production reported no output.\n", fallback_ready ? "reached READY on its fake fallback" : "failed READY");
    } else printf("autoaudiosink not installed: its fake-fallback fixture was NOT executed here; the missing-autoaudiosink path below is the production path.\n");

    /* Qualification is exact name + Sink class + raw-audio sink pad; never one alone. */
    REQUIRE(gst_element_register(NULL, "peeltestvideosink", GST_RANK_NONE, peel_test_video_sink_get_type()));
    REQUIRE(gst_element_register(NULL, "peeltestaudiosink", GST_RANK_NONE, peel_test_audio_sink_get_type()));
    REQUIRE(!factory_flag("peeltestvideosink", peel_audio_factory_accepts_pcm) && !factory_flag("peeltestvideosink", peel_audio_factory_qualified));
    REQUIRE(factory_flag("peeltestaudiosink", peel_audio_factory_accepts_pcm) && !factory_flag("peeltestaudiosink", peel_audio_factory_qualified)); /* audio caps, but not an allowlisted backend */
    REQUIRE(!factory_flag("fakesink", peel_audio_factory_qualified)); /* ANY caps, never a backend */
    checked = bin_of(gst_element_factory_make("peeltestvideosink", NULL), NULL); REQUIRE(!peel_audio_sink_is_real(checked)); gst_object_unref(checked);
    REQUIRE(!peel_audio_factory_qualified(NULL) && !peel_audio_factory_accepts_pcm(NULL));

    /* Missing-autoaudiosink path, exercised in every environment by detaching it
     * process-locally. Selection reads registry metadata only; no installed real
     * sink is set to READY here. */
    GstPluginFeature *automatic_detached = detach_feature("autoaudiosink");
    REQUIRE(!gst_element_factory_find("autoaudiosink"));
    gboolean pipewire_ok = installed_qualified("pipewiresink"), alsa_ok = installed_qualified("alsasink");
    const char *expected = pipewire_ok ? "pipewiresink" : alsa_ok ? "alsasink" : NULL;
    const char *choice = peel_audio_output_choice();
    REQUIRE(g_strcmp0(choice, expected) == 0 && g_strcmp0(peel_audio_fallback_choice(), expected) == 0);
    printf("Without autoaudiosink, installed qualified backends: pipewiresink=%s alsasink=%s; production choice=%s. Opening it (READY/PLAYING) was NOT executed by this fixture.\n",
        pipewire_ok ? "yes" : "no", alsa_ok ? "yes" : "no", choice ? choice : "none");
    for (int i = 0; i < 2; i++) {
        const char *name = i == 0 ? "pipewiresink" : "alsasink";
        if (!installed_qualified(name)) continue;
        GstElement *backend = gst_element_factory_make(name, NULL); /* instantiated only, never READY */
        REQUIRE(backend != NULL);
        checked = bin_of(backend, gst_element_factory_make("audioconvert", NULL));
        REQUIRE(peel_audio_sink_is_real(checked)); gst_object_unref(checked);
    }

    /* Deterministic order: with pipewiresink detached the choice moves to a qualified
     * alsasink, else none. A video-only impostor registered under the pipewiresink
     * name is refused by its caps, not accepted by its name. */
    GstPluginFeature *pipewire = detach_feature("pipewiresink");
    REQUIRE(g_strcmp0(peel_audio_output_choice(), alsa_ok ? "alsasink" : NULL) == 0);
    REQUIRE(gst_element_register(NULL, "pipewiresink", GST_RANK_PRIMARY, peel_test_impostor_sink_get_type()));
    REQUIRE(!factory_flag("pipewiresink", peel_audio_factory_qualified));
    REQUIRE(g_strcmp0(peel_audio_output_choice(), alsa_ok ? "alsasink" : NULL) == 0);
    checked = bin_of(gst_element_factory_make("pipewiresink", NULL), NULL); REQUIRE(!peel_audio_sink_is_real(checked)); gst_object_unref(checked);
    GstPluginFeature *impostor = detach_feature("pipewiresink");
    REQUIRE(impostor != NULL); gst_object_unref(impostor);

    /* No qualified backend at all: production reports no output and opens nothing.
     * Device-free, because no candidate remains to be opened. */
    GstPluginFeature *alsa = detach_feature("alsasink");
    REQUIRE(peel_audio_output_choice() == NULL);
    REQUIRE(peel_linux_audio_available() == 0);
    peel_linux_receiver_generation(10);
    REQUIRE(peel_linux_audio_new(10) == NULL);
    attach_feature(alsa); attach_feature(pipewire); attach_feature(automatic_detached);
    REQUIRE(automatic_feature == NULL || !strcmp(peel_audio_output_choice(), "autoaudiosink"));
    if (automatic_feature) gst_object_unref(automatic_feature);

    printf("%u receiver audio sink assertions passed. Substituted, test-registered and registry-detached elements only; no installed sink was opened, so no audible playback, device or latency is proved.\n", assertions);
    return 0;
}
