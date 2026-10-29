#include "internal.h"
#include "encoder_internal.h"
#include <libportal/portal.h>
#include <libportal-gtk4/portal-gtk4.h>
#include <unistd.h>
#include <string.h>

G_LOCK_DEFINE_STATIC(receiver_registry);
static GSList *receiver_surfaces;
static uint64_t receiver_generation;
static gboolean receiver_current(uint64_t generation) {
    G_LOCK(receiver_registry); gboolean current = generation == receiver_generation; G_UNLOCK(receiver_registry); return current;
}
gboolean peel_receiver_current(uint64_t generation) { return receiver_current(generation); }

struct PeelSurface {
    gatomicrefcount refs;
    GMutex lock;
    gboolean closed, queued;
    GBytes *pixels;
    int width, height, stride;
    guint64 frames;
    gboolean sized;
    uint64_t session_generation;
    uint32_t window_id;
    char *title;
    GtkWindow *window;
    GtkPicture *picture;
};
PeelSurface *peel_surface_ref(PeelSurface *s) { g_atomic_ref_count_inc(&s->refs); return s; }
void peel_surface_unref(PeelSurface *s) {
    if (!g_atomic_ref_count_dec(&s->refs)) return;
    g_clear_pointer(&s->pixels, g_bytes_unref); g_free(s->title); g_mutex_clear(&s->lock); g_free(s);
}
static void surface_user_stop(PeelSurface *surface);
static gboolean surface_user_closed(GtkWindow *window, gpointer data) {
    (void)window; PeelSurface *s = data;
    g_mutex_lock(&s->lock); gboolean already_closed = s->closed; s->closed = TRUE; s->picture = NULL;
    g_clear_pointer(&s->pixels, g_bytes_unref); g_mutex_unlock(&s->lock);
    if (!already_closed) surface_user_stop(s); return FALSE;
}
static gboolean surface_create(gpointer data) {
    PeelSurface *s = data;
    g_mutex_lock(&s->lock);
    if (!s->closed) {
        char *named = s->window_id ? peel_ui_window_title(s->window_id, s->session_generation) : NULL;
        if (named) { g_free(s->title); s->title = g_strdup_printf("%s — Peel Pro", named); g_free(named); }
        s->window = GTK_WINDOW(gtk_window_new()); g_object_ref_sink(s->window);
        g_signal_connect(s->window, "close-request", G_CALLBACK(surface_user_closed), s);
        gtk_window_set_title(s->window, s->title); gtk_window_set_default_size(s->window, 960, 540);
        s->picture = GTK_PICTURE(gtk_picture_new());
        gtk_picture_set_content_fit(s->picture, GTK_CONTENT_FIT_CONTAIN);
        gtk_picture_set_can_shrink(s->picture, TRUE);
        GtkWidget *content = GTK_WIDGET(s->picture);
        GtkWidget *controls = s->window_id ? peel_viewer_controls_new(s->session_generation, s->window_id) : NULL;
        if (controls) {
            /* Receiver viewers only: source controls above the picture; the local source preview is unchanged. */
            content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0); gtk_widget_set_vexpand(GTK_WIDGET(s->picture), TRUE);
            gtk_box_append(GTK_BOX(content), controls); gtk_box_append(GTK_BOX(content), GTK_WIDGET(s->picture));
        }
        gtk_window_set_child(s->window, content);
        gtk_window_present(s->window);
    }
    g_mutex_unlock(&s->lock); return G_SOURCE_REMOVE;
}
static PeelSurface *surface_new_bound(const char *title, uint64_t generation, uint32_t window) {
    PeelSurface *s = g_new0(PeelSurface, 1); g_atomic_ref_count_init(&s->refs); g_mutex_init(&s->lock);
    s->title = g_strdup(title); s->session_generation = generation; s->window_id = window;
    if (window) {
        G_LOCK(receiver_registry);
        if (generation != receiver_generation) s->closed = TRUE;
        else receiver_surfaces = g_slist_prepend(receiver_surfaces, peel_surface_ref(s));
        G_UNLOCK(receiver_registry);
    }
    g_idle_add_full(G_PRIORITY_DEFAULT, surface_create, peel_surface_ref(s), (GDestroyNotify)peel_surface_unref);
    return s;
}
PeelSurface *peel_surface_new(const char *title) { return surface_new_bound(title, 0, 0); }
static gboolean surface_flush(gpointer data) {
    PeelSurface *s = data;
    g_mutex_lock(&s->lock); s->queued = FALSE;
    if (!s->closed && s->picture && s->pixels) {
        GdkTexture *texture = gdk_memory_texture_new(s->width, s->height, GDK_MEMORY_B8G8R8A8,
                                                   s->pixels, s->stride);
        gtk_picture_set_paintable(s->picture, GDK_PAINTABLE(texture)); g_object_unref(texture);
        if (!s->sized) {
            double scale = MIN(1.0, MIN(1280.0 / s->width, 800.0 / s->height));
            gtk_window_set_default_size(s->window, MAX(1, (int)(s->width * scale)), MAX(1, (int)(s->height * scale))); s->sized = TRUE;
        }
        char *title = g_strdup_printf("%s · %d×%d · frame %" G_GUINT64_FORMAT, s->title, s->width, s->height, s->frames);
        gtk_window_set_title(s->window, title); g_free(title);
        g_clear_pointer(&s->pixels, g_bytes_unref);
    }
    g_mutex_unlock(&s->lock); return G_SOURCE_REMOVE;
}
void peel_surface_sample(PeelSurface *s, GstSample *sample) {
    GstVideoInfo info; GstVideoFrame frame;
    if (!sample || !gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) ||
        GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_BGRA ||
        info.width < 1 || info.height < 1 || info.width > 8192 || info.height > 8192 ||
        (guint64)info.width * info.height > 33554432 ||
        !gst_video_frame_map(&frame, &info, gst_sample_get_buffer(sample), GST_MAP_READ)) return;
    int stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
    size_t row = (size_t)info.width * 4, total = row * info.height;
    if (stride < 0 || (size_t)stride < row) { gst_video_frame_unmap(&frame); return; }
    guint8 *copy = g_malloc(total);
    for (int y = 0; y < info.height; y++) memcpy(copy + y * row, (guint8 *)GST_VIDEO_FRAME_PLANE_DATA(&frame, 0) + y * stride, row);
    gst_video_frame_unmap(&frame);
    GBytes *bytes = g_bytes_new_take(copy, total);
    g_mutex_lock(&s->lock);
    if (!s->closed) {
        g_clear_pointer(&s->pixels, g_bytes_unref); s->pixels = bytes; bytes = NULL;
        s->width = info.width; s->height = info.height; s->stride = (int)row; s->frames++;
        if (!s->queued) { s->queued = TRUE; g_idle_add_full(G_PRIORITY_DEFAULT, surface_flush, peel_surface_ref(s), (GDestroyNotify)peel_surface_unref); }
    }
    g_mutex_unlock(&s->lock); if (bytes) g_bytes_unref(bytes);
}
static gboolean surface_destroy(gpointer data) {
    PeelSurface *s = data;
    if (s->window) { g_signal_handlers_disconnect_by_data(s->window, s); gtk_window_destroy(s->window); g_clear_object(&s->window); s->picture = NULL; }
    return G_SOURCE_REMOVE;
}
void peel_surface_close(PeelSurface *s) {
    gboolean registered = FALSE;
    G_LOCK(receiver_registry);
    if (g_slist_find(receiver_surfaces, s)) { receiver_surfaces = g_slist_remove(receiver_surfaces, s); registered = TRUE; }
    G_UNLOCK(receiver_registry);
    g_mutex_lock(&s->lock); s->closed = TRUE; g_clear_pointer(&s->pixels, g_bytes_unref); g_mutex_unlock(&s->lock);
    g_idle_add_full(G_PRIORITY_DEFAULT, surface_destroy, peel_surface_ref(s), (GDestroyNotify)peel_surface_unref);
    if (registered) peel_surface_unref(s);
}
void peel_linux_receiver_generation(uint64_t generation) {
    G_LOCK(receiver_registry); receiver_generation = generation;
    GSList *old = g_slist_copy(receiver_surfaces);
    for (GSList *item = old; item; item = item->next) peel_surface_ref(item->data);
    G_UNLOCK(receiver_registry);
    for (GSList *item = old; item; item = item->next) { peel_surface_close(item->data); peel_surface_unref(item->data); }
    g_slist_free(old);
}
typedef struct { PeelSurface *surface; uint64_t capture_generation; } SampleTarget;
static void sample_target_free(gpointer data) {
    SampleTarget *target = data; peel_surface_unref(target->surface); g_free(target);
}
static GstFlowReturn sample_ready(GstAppSink *sink, gpointer data) {
    SampleTarget *target = data;
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (sample) {
        if (target->capture_generation) peel_encoder_capture_sample(target->capture_generation, sample);
        peel_surface_sample(target->surface, sample); gst_sample_unref(sample);
    }
    return GST_FLOW_OK;
}
static void wire_sink(GstElement *pipeline, PeelSurface *surface, uint64_t capture_generation) {
    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "frames");
    SampleTarget *target = g_new0(SampleTarget, 1);
    target->surface = peel_surface_ref(surface); target->capture_generation = capture_generation;
    GstAppSinkCallbacks callbacks = { .new_sample = sample_ready };
    gst_app_sink_set_callbacks(GST_APP_SINK(sink), &callbacks, target, sample_target_free);
    gst_object_unref(sink);
}
static gboolean media_bus(GstBus *bus, GstMessage *message, gpointer unused) {
    (void)bus; (void)unused;
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) peel_linux_status("The connected computer’s stream could not be decoded. Close its viewer and open the window again.");
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) peel_linux_status("The connected computer’s stream ended.");
    return G_SOURCE_CONTINUE;
}

typedef struct {
    gatomicrefcount refs;
    guint64 epoch;
    uint32_t source_kind;
    GCancellable *cancel;
    XdpPortal *portal;
    XdpSession *session;
    XdpParent *parent;
    gboolean control;
    int fd;
    GstElement *pipeline;
    guint bus_watch, setup_timeout;
    PeelSurface *surface;
} Host;
static Host *current_host;
static guint64 host_epoch;
static void surface_user_stop(PeelSurface *surface) {
    if (current_host && current_host->surface == surface) { peel_host_stop(); peel_share_status("Preview closed, so sharing stopped. Choose a source to share again."); }
    else if (surface->window_id) peel_ui_video_closed(surface->window_id, surface->session_generation);
}
static Host *host_ref(Host *h) { g_atomic_ref_count_inc(&h->refs); return h; }
static void host_unref(Host *h) {
    if (!g_atomic_ref_count_dec(&h->refs)) return;
    if (h->parent) xdp_parent_free(h->parent);
    g_clear_object(&h->cancel); g_clear_object(&h->portal); g_free(h);
}
void peel_host_stop(void) {
    Host *h = current_host; current_host = NULL; host_epoch++;
    if (!h) return;
    peel_encoder_capture_close(h->epoch); /* fence encoded delivery before capture drain */
    g_cancellable_cancel(h->cancel);
    if (h->session) g_signal_handlers_disconnect_by_data(h->session, h);
    if (h->setup_timeout) { g_source_remove(h->setup_timeout); h->setup_timeout = 0; }
    if (h->bus_watch) g_source_remove(h->bus_watch);
    if (h->pipeline) { gst_element_set_state(h->pipeline, GST_STATE_NULL); gst_object_unref(h->pipeline); h->pipeline = NULL; }
    if (h->fd >= 0) { close(h->fd); h->fd = -1; }
    if (h->surface) { peel_surface_close(h->surface); peel_surface_unref(h->surface); h->surface = NULL; }
    if (h->session) { xdp_session_close(h->session); g_clear_object(&h->session); }
    host_unref(h);
}
static gboolean host_bus(GstBus *bus, GstMessage *message, gpointer data) {
    (void)bus; Host *h = data;
    if (h == current_host && (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR || GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS)) {
        peel_host_stop(); peel_share_status("The shared source ended. Choose a source again."); return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}
static void portal_closed(XdpSession *session, gpointer data) {
    (void)session; Host *h = data;
    if (h == current_host) { peel_host_stop(); peel_share_status("Sharing ended by the desktop portal."); }
}
static void started(GObject *source, GAsyncResult *result, gpointer data) {
    Host *h = data; GError *error = NULL;
    gboolean ok = xdp_session_start_finish(XDP_SESSION(source), result, &error);
    if (h != current_host || h->epoch != host_epoch || !ok) {
        g_clear_error(&error); if (h == current_host) { peel_host_stop(); peel_share_status("Source selection cancelled or unavailable."); } host_unref(h); return;
    }
    if (h->setup_timeout) { g_source_remove(h->setup_timeout); h->setup_timeout = 0; }
    GVariant *streams = xdp_session_get_streams(h->session);
    guint32 node = 0; guint64 serial = 0; GVariant *properties = NULL;
    if (!streams || g_variant_n_children(streams) != 1) { peel_host_stop(); host_unref(h); return; }
    g_variant_get_child(streams, 0, "(u@a{sv})", &node, &properties);
    g_variant_lookup(properties, "pipewire-serial", "t", &serial);
    g_variant_lookup(properties, "source_type", "u", &h->source_kind); g_variant_unref(properties);
    h->fd = xdp_session_open_pipewire_remote(h->session);
    if (h->fd < 0 || node == 0) { peel_host_stop(); host_unref(h); return; }
    h->pipeline = gst_parse_launch("pipewiresrc name=source do-timestamp=true ! queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=downstream ! videoconvert ! video/x-raw,format=BGRA ! appsink name=frames max-buffers=1 drop=true sync=false", &error);
    if (!h->pipeline || error) { g_clear_error(&error); peel_host_stop(); peel_share_status("PipeWire capture plugin unavailable."); host_unref(h); return; }
    GstElement *pw = gst_bin_get_by_name(GST_BIN(h->pipeline), "source");
    GObjectClass *type = G_OBJECT_GET_CLASS(pw);
    if (!g_object_class_find_property(type, "dont-reconnect") ||
        (serial && !g_object_class_find_property(type, "target-object"))) {
        gst_object_unref(pw); peel_host_stop(); peel_share_status("PipeWire plugin lacks safe source targeting."); host_unref(h); return;
    }
    g_object_set(pw, "fd", h->fd, "dont-reconnect", TRUE, NULL);
    if (serial) {
        char *target = g_strdup_printf("%" G_GUINT64_FORMAT, serial);
        g_object_set(pw, "target-object", target, NULL); g_free(target);
    } else {
        // Legacy node ID never leaves this restricted live session. Reconnect
        // is disabled; Stop creates a new epoch and requires fresh selection.
        char *path = g_strdup_printf("%u", node); g_object_set(pw, "path", path, NULL); g_free(path);
    }
    if (g_object_class_find_property(type, "on-disconnect")) g_object_set(pw, "on-disconnect", 2, NULL);
    if (g_object_class_find_property(type, "max-buffers")) g_object_set(pw, "max-buffers", 3, NULL);
    gst_object_unref(pw);
    h->surface = peel_surface_new("Peel Pro — Source preview · close to stop sharing"); wire_sink(h->pipeline, h->surface, h->epoch);
    GstBus *bus = gst_element_get_bus(h->pipeline); h->bus_watch = gst_bus_add_watch(bus, host_bus, h); gst_object_unref(bus);
    peel_encoder_capture_open(h->epoch, h->source_kind);
    if (gst_element_set_state(h->pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) { peel_host_stop(); peel_share_status("Capture could not start."); }
    else peel_share_status(peel_host_ui_registered() ? "Source chosen; local preview open. Paired devices see it only after Share selected source."
        : "Source chosen; local preview open. This preview build does not share over the network.");
    host_unref(h);
}
static void created(GObject *source, GAsyncResult *result, gpointer data) {
    Host *h = data; GError *error = NULL;
    XdpSession *session = h->control
        ? xdp_portal_create_remote_desktop_session_finish(XDP_PORTAL(source), result, &error)
        : xdp_portal_create_screencast_session_finish(XDP_PORTAL(source), result, &error);
    if (h != current_host || h->epoch != host_epoch || !session) {
        if (session) { xdp_session_close(session); g_object_unref(session); }
        g_clear_error(&error); if (h == current_host) { peel_host_stop(); peel_share_status("Desktop portal did not grant a source."); } host_unref(h); return;
    }
    h->session = session; g_signal_connect(session, "closed", G_CALLBACK(portal_closed), h);
    xdp_session_start(session, h->parent, h->cancel, started, host_ref(h)); host_unref(h);
}
static gboolean setup_expired(gpointer data) {
    Host *h = data; h->setup_timeout = 0;
    if (h == current_host) { peel_host_stop(); peel_share_status("Source selection expired. Choose again when ready."); }
    return G_SOURCE_REMOVE;
}
void peel_host_choose(GtkWindow *parent, gboolean control) {
    peel_host_stop(); Host *h = g_new0(Host, 1); g_atomic_ref_count_init(&h->refs);
    h->epoch = host_epoch; h->fd = -1; h->control = control;
    h->cancel = g_cancellable_new(); h->portal = xdp_portal_new(); h->parent = xdp_parent_new_gtk(parent); current_host = h;
    h->setup_timeout = g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, 120, setup_expired, host_ref(h), (GDestroyNotify)host_unref);
    if (control) xdp_portal_create_remote_desktop_session(h->portal, XDP_DEVICE_KEYBOARD | XDP_DEVICE_POINTER,
        XDP_OUTPUT_MONITOR | XDP_OUTPUT_WINDOW, XDP_REMOTE_DESKTOP_FLAG_NONE, XDP_CURSOR_MODE_EMBEDDED,
        h->cancel, created, host_ref(h));
    else xdp_portal_create_screencast_session(h->portal, XDP_OUTPUT_MONITOR | XDP_OUTPUT_WINDOW,
        XDP_SCREENCAST_FLAG_NONE, XDP_CURSOR_MODE_EMBEDDED, XDP_PERSIST_MODE_NONE, NULL, h->cancel, created, host_ref(h));
}

typedef struct { GMutex lock; gboolean closed; uint64_t generation; uint32_t id; GstElement *pipeline, *source; guint bus_watch; PeelSurface *surface; } Decoder;
void *peel_linux_decoder_new(uint64_t generation, uint32_t id) {
    if (!id || !receiver_current(generation)) return NULL;
    Decoder *d = g_new0(Decoder, 1); g_mutex_init(&d->lock); d->generation = generation; d->id = id;
    d->surface = surface_new_bound("Peel Pro — Connected computer", generation, id); return d;
}
int peel_linux_decoder_configure(void *handle, uint32_t width, uint32_t height, const uint8_t *parameters, size_t size) {
    Decoder *d = handle;
    if (!d || !parameters || size == 0 || size > 1048576 || !width || !height || width > 8192 || height > 8192 || (uint64_t)width * height > 33554432) return 0;
    g_mutex_lock(&d->lock);
    if (d->closed || !receiver_current(d->generation)) { g_mutex_unlock(&d->lock); return 0; }
    if (d->bus_watch) { g_source_remove(d->bus_watch); d->bus_watch = 0; }
    if (d->pipeline) { gst_element_set_state(d->pipeline, GST_STATE_NULL); gst_object_unref(d->pipeline); d->pipeline = NULL; g_clear_object(&d->source); }
    GError *error = NULL;
    d->pipeline = gst_parse_launch("appsrc name=encoded is-live=true format=time block=false max-bytes=8388608 ! h264parse ! avdec_h264 ! videoconvert ! video/x-raw,format=BGRA ! appsink name=frames max-buffers=1 drop=true sync=false", &error);
    if (!d->pipeline || error) { g_clear_error(&error); if (d->pipeline) { gst_object_unref(d->pipeline); d->pipeline = NULL; } g_mutex_unlock(&d->lock); return 0; }
    d->source = gst_bin_get_by_name(GST_BIN(d->pipeline), "encoded");
    GstCaps *caps = gst_caps_new_simple("video/x-h264", "stream-format", G_TYPE_STRING, "byte-stream", "alignment", G_TYPE_STRING, "au", NULL);
    gst_app_src_set_caps(GST_APP_SRC(d->source), caps); gst_caps_unref(caps); wire_sink(d->pipeline, d->surface, 0);
    GstBus *bus = gst_element_get_bus(d->pipeline); d->bus_watch = gst_bus_add_watch(bus, media_bus, NULL); gst_object_unref(bus);
    gboolean ok = gst_element_set_state(d->pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE;
    if (ok) { GstBuffer *buffer = gst_buffer_new_allocate(NULL, size, NULL); gst_buffer_fill(buffer, 0, parameters, size); ok = gst_app_src_push_buffer(GST_APP_SRC(d->source), buffer) == GST_FLOW_OK; }
    g_mutex_unlock(&d->lock); return ok;
}
int peel_linux_decoder_push(void *handle, const uint8_t *bytes, size_t size, uint64_t pts, uint64_t duration) {
    Decoder *d = handle; if (!d || !bytes || size == 0 || size > 8388608) return 0;
    g_mutex_lock(&d->lock);
    g_mutex_lock(&d->surface->lock); gboolean surface_closed = d->surface->closed; g_mutex_unlock(&d->surface->lock);
    if (d->closed || !receiver_current(d->generation) || surface_closed || !d->source || gst_app_src_get_current_level_bytes(GST_APP_SRC(d->source)) + size > 8388608) { g_mutex_unlock(&d->lock); return 0; }
    GstBuffer *buffer = gst_buffer_new_allocate(NULL, size, NULL); gst_buffer_fill(buffer, 0, bytes, size);
    GST_BUFFER_PTS(buffer) = pts; GST_BUFFER_DURATION(buffer) = duration;
    gboolean ok = gst_app_src_push_buffer(GST_APP_SRC(d->source), buffer) == GST_FLOW_OK;
    g_mutex_unlock(&d->lock); return ok;
}
void peel_linux_decoder_free(void *handle) {
    Decoder *d = handle; if (!d) return;
    g_mutex_lock(&d->lock); d->closed = TRUE;
    if (d->bus_watch) g_source_remove(d->bus_watch);
    if (d->pipeline) { gst_element_set_state(d->pipeline, GST_STATE_NULL); gst_object_unref(d->pipeline); }
    g_clear_object(&d->source); peel_surface_close(d->surface); peel_surface_unref(d->surface);
    g_mutex_unlock(&d->lock); g_mutex_clear(&d->lock); g_free(d);
}
