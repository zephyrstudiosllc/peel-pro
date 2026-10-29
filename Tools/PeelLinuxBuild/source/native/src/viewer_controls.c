#include "internal.h"
#include <math.h>
#include <string.h>

/* Receiver viewer toolbar. Every control targets the streamed SOURCE through the
 * managed owner of this exact window/receiver generation; nothing here touches
 * receiver OS volume, desktop media-player sessions or media keys. Widgets show
 * only actual state pushed by managed code: a click sends a request and the
 * widget returns to the last actual state until the source answers. Listen is
 * the one receiver-side choice: whether the source's audio plays here. GTK main
 * only, except the entry points that copy and marshal. Hiding a group never
 * sends a command. */
typedef struct {
    uint64_t generation;
    uint32_t window;
    gboolean updating;
    PeelViewerState state;
    GtkWidget *root, *listen, *note, *volume_group, *mute, *volume_menu, *scale, *media_group, *previous, *play_pause, *next;
} Controls;

static GSList *controls_list; /* GTK main only */
static PeelViewerControl viewer_control;
static void *viewer_user;
static gint show_volume = 1, show_media = 1; /* atomic; presentation only */
static GtkCheckButton *volume_setting, *media_setting;
static gboolean settings_updating;

void peel_linux_viewer_register(PeelViewerControl control, void *user) { viewer_control = control; viewer_user = user; }

static void dispatch_control(Controls *c, int32_t command, double value) {
    if (viewer_control && !c->updating) viewer_control(c->window, c->generation, command, value, viewer_user);
}

static void apply(Controls *c) {
    const PeelViewerState *s = &c->state;
    c->updating = TRUE;
    gboolean listening = s->audio == PEEL_AUDIO_STARTING || s->audio == PEEL_AUDIO_PLAYING;
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(c->listen), listening);
    gtk_widget_set_sensitive(c->listen, s->listen_enabled != 0);
    gtk_widget_set_tooltip_text(c->listen,
        s->audio == PEEL_AUDIO_UNAVAILABLE ? "Listen unavailable: this computer has no working audio output, or the source doesn't share audio." :
        s->audio == PEEL_AUDIO_OFF ? "Listen is off for this computer. Turn it on to play the source's audio here." :
        s->audio == PEEL_AUDIO_PLAYING ? "Playing the source's audio here. Turn off to stop; that choice is remembered for this computer." :
        s->audio == PEEL_AUDIO_STARTING ? "Connecting to the source's audio…" :
        s->audio == PEEL_AUDIO_FAILED ? "Source audio stopped. Turn on to try again." : "Listen: play the source's audio here.");
    gboolean media = s->media_enabled != 0;
    gtk_widget_set_sensitive(c->previous, media); gtk_widget_set_sensitive(c->play_pause, media); gtk_widget_set_sensitive(c->next, media);
    const char *media_off = "The source computer doesn't offer media keys.";
    gtk_widget_set_tooltip_text(c->previous, media ? "Previous track on the source computer" : media_off);
    gtk_widget_set_tooltip_text(c->play_pause, media ? "Play or pause on the source computer" : media_off);
    gtk_widget_set_tooltip_text(c->next, media ? "Next track on the source computer" : media_off);
    gboolean can_mute = s->volume_supported && s->can_set_mute, can_volume = s->volume_supported && s->can_set_volume;
    gtk_widget_set_sensitive(c->mute, can_mute); gtk_widget_set_sensitive(c->volume_menu, can_volume);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(c->mute), s->volume_supported && s->muted == 1);
    gtk_button_set_icon_name(GTK_BUTTON(c->mute), s->volume_supported && s->muted == 1 ? "audio-volume-muted-symbolic" : "audio-volume-high-symbolic");
    const char *volume_off = "The source computer doesn't offer volume control.";
    gtk_widget_set_tooltip_text(c->mute, can_mute ? "Mute or unmute the source computer" : volume_off);
    gtk_widget_set_tooltip_text(c->volume_menu, can_volume ? "Source computer volume" : volume_off);
    if (s->volume_supported && s->volume >= 0 && s->volume <= 1) gtk_range_set_value(GTK_RANGE(c->scale), s->volume * 100.0);
    gtk_widget_set_visible(c->volume_group, g_atomic_int_get(&show_volume) != 0);
    gtk_widget_set_visible(c->media_group, g_atomic_int_get(&show_media) != 0);
    c->updating = FALSE;
}

static void listen_toggled(GtkToggleButton *button, gpointer data) {
    Controls *c = data; if (c->updating) return;
    dispatch_control(c, gtk_toggle_button_get_active(button) ? PEEL_VIEWER_LISTEN_ON : PEEL_VIEWER_LISTEN_OFF, 0);
    apply(c); /* Back to actual state until managed reports the result. */
}
static void mute_toggled(GtkToggleButton *button, gpointer data) {
    Controls *c = data; if (c->updating) return;
    dispatch_control(c, PEEL_VIEWER_MUTE_SET, gtk_toggle_button_get_active(button) ? 1 : 0); apply(c);
}
static void volume_changed(GtkRange *range, gpointer data) {
    Controls *c = data; if (c->updating) return;
    double value = gtk_range_get_value(range) / 100.0;
    if (isfinite(value) && value >= 0 && value <= 1) dispatch_control(c, PEEL_VIEWER_VOLUME_SET, value);
}
static void volume_shown(GtkWidget *popover, gpointer data) { (void)popover; dispatch_control(data, PEEL_VIEWER_VOLUME_QUERY, 0); }
static void media_clicked(GtkButton *button, gpointer data) {
    Controls *c = data;
    dispatch_control(c, GTK_WIDGET(button) == c->previous ? PEEL_VIEWER_PREVIOUS : GTK_WIDGET(button) == c->next ? PEEL_VIEWER_NEXT : PEEL_VIEWER_PLAY_PAUSE, 0);
}
/* Dispose: stop routing state here. The struct itself is freed with the root's
 * data at finalize, after every child (and its signal handlers) is gone. */
static void controls_destroyed(GtkWidget *root, gpointer data) { (void)root; controls_list = g_slist_remove(controls_list, data); }

typedef struct { uint64_t generation; uint32_t window; } ShownTarget;
static gboolean announce_shown(gpointer data) {
    ShownTarget *t = data;
    for (GSList *item = controls_list; item; item = item->next) {
        Controls *c = item->data;
        if (c->generation == t->generation && c->window == t->window) { dispatch_control(c, PEEL_VIEWER_SHOWN, 0); break; }
    }
    return G_SOURCE_REMOVE;
}

static GtkWidget *icon_button(GtkBox *box, const char *icon, GCallback clicked, Controls *c) {
    GtkWidget *button = gtk_button_new_from_icon_name(icon); gtk_widget_add_css_class(button, "flat");
    g_signal_connect(button, "clicked", clicked, c); gtk_box_append(box, button); return button;
}

GtkWidget *peel_viewer_controls_new(uint64_t generation, uint32_t window) {
    if (!window) return NULL;
    Controls *c = g_new0(Controls, 1); c->generation = generation; c->window = window;
    c->state.audio = PEEL_AUDIO_UNAVAILABLE; c->state.muted = -1; c->state.volume = -1;
    c->root = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4); gtk_widget_add_css_class(c->root, "toolbar");
    gtk_widget_set_margin_start(c->root, 4); gtk_widget_set_margin_end(c->root, 4);
    c->listen = gtk_toggle_button_new(); gtk_button_set_icon_name(GTK_BUTTON(c->listen), "audio-speakers-symbolic");
    gtk_widget_add_css_class(c->listen, "flat"); gtk_box_append(GTK_BOX(c->root), c->listen);
    g_signal_connect(c->listen, "toggled", G_CALLBACK(listen_toggled), c);
    c->note = gtk_label_new(""); gtk_label_set_ellipsize(GTK_LABEL(c->note), PANGO_ELLIPSIZE_END); gtk_label_set_xalign(GTK_LABEL(c->note), 0);
    gtk_widget_add_css_class(c->note, "dim-label"); gtk_widget_set_hexpand(c->note, TRUE); gtk_box_append(GTK_BOX(c->root), c->note);

    c->volume_group = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2); gtk_box_append(GTK_BOX(c->root), c->volume_group);
    c->mute = gtk_toggle_button_new(); gtk_widget_add_css_class(c->mute, "flat"); gtk_box_append(GTK_BOX(c->volume_group), c->mute);
    g_signal_connect(c->mute, "toggled", G_CALLBACK(mute_toggled), c);
    c->volume_menu = gtk_menu_button_new(); gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(c->volume_menu), "pan-down-symbolic");
    gtk_widget_add_css_class(c->volume_menu, "flat"); gtk_box_append(GTK_BOX(c->volume_group), c->volume_menu);
    GtkWidget *popover = gtk_popover_new();
    c->scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 100, 1); gtk_scale_set_draw_value(GTK_SCALE(c->scale), FALSE);
    gtk_widget_set_size_request(c->scale, 160, -1); gtk_popover_set_child(GTK_POPOVER(popover), c->scale);
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(c->volume_menu), popover);
    g_signal_connect(popover, "show", G_CALLBACK(volume_shown), c);
    g_signal_connect(c->scale, "value-changed", G_CALLBACK(volume_changed), c);

    c->media_group = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2); gtk_box_append(GTK_BOX(c->root), c->media_group);
    c->previous = icon_button(GTK_BOX(c->media_group), "media-skip-backward-symbolic", G_CALLBACK(media_clicked), c);
    c->play_pause = icon_button(GTK_BOX(c->media_group), "media-playback-start-symbolic", G_CALLBACK(media_clicked), c);
    c->next = icon_button(GTK_BOX(c->media_group), "media-skip-forward-symbolic", G_CALLBACK(media_clicked), c);

    g_object_set_data_full(G_OBJECT(c->root), "peel-viewer-controls", c, g_free);
    g_signal_connect(c->root, "destroy", G_CALLBACK(controls_destroyed), c);
    controls_list = g_slist_prepend(controls_list, c);
    apply(c);
    /* Ask for current state after creation, outside the caller's surface lock. */
    ShownTarget *t = g_new0(ShownTarget, 1); t->generation = generation; t->window = window;
    g_idle_add_full(G_PRIORITY_DEFAULT, announce_shown, t, g_free);
    return c->root;
}

typedef struct { uint64_t generation; uint32_t window; PeelViewerState state; char *note; } StateUpdate;
static void free_update(gpointer data) { StateUpdate *u = data; g_free(u->note); g_free(u); }
static gboolean show_state(gpointer data) {
    StateUpdate *u = data;
    for (GSList *item = controls_list; item; item = item->next) {
        Controls *c = item->data;
        if (c->generation != u->generation || c->window != u->window) continue;
        c->state = u->state; apply(c);
        if (u->note) gtk_label_set_text(GTK_LABEL(c->note), u->note);
    }
    return G_SOURCE_REMOVE;
}
void peel_linux_viewer_state(uint64_t generation, uint32_t window, const PeelViewerState *state, const char *note) {
    if (!state || !window || (note && (strlen(note) > 512 || !g_utf8_validate(note, -1, NULL)))) return;
    StateUpdate *u = g_new0(StateUpdate, 1); u->generation = generation; u->window = window; u->state = *state;
    if (!(isfinite(u->state.volume) && u->state.volume >= 0 && u->state.volume <= 1)) u->state.volume = -1;
    if (u->state.muted != 0 && u->state.muted != 1) u->state.muted = -1;
    u->note = note ? g_strdup(note) : NULL;
    g_idle_add_full(G_PRIORITY_DEFAULT, show_state, u, free_update);
}

static gboolean show_visibility(gpointer unused) {
    (void)unused;
    settings_updating = TRUE;
    if (volume_setting) gtk_check_button_set_active(volume_setting, g_atomic_int_get(&show_volume) != 0);
    if (media_setting) gtk_check_button_set_active(media_setting, g_atomic_int_get(&show_media) != 0);
    settings_updating = FALSE;
    for (GSList *item = controls_list; item; item = item->next) apply(item->data);
    return G_SOURCE_REMOVE;
}
void peel_linux_viewer_visibility(int32_t volume, int32_t media) {
    g_atomic_int_set(&show_volume, volume != 0); g_atomic_int_set(&show_media, media != 0);
    g_idle_add(show_visibility, NULL);
}
static void setting_toggled(GtkCheckButton *button, gpointer unused) {
    (void)unused; if (settings_updating) return;
    gboolean active = gtk_check_button_get_active(button), volume = button == volume_setting;
    g_atomic_int_set(volume ? &show_volume : &show_media, active);
    for (GSList *item = controls_list; item; item = item->next) apply(item->data);
    if (viewer_control) viewer_control(0, 0, volume ? PEEL_VIEWER_SHOW_VOLUME : PEEL_VIEWER_SHOW_MEDIA, active ? 1 : 0, viewer_user);
}
static void setting_destroyed(GtkWidget *widget, gpointer unused) {
    (void)unused;
    if (widget == GTK_WIDGET(volume_setting)) volume_setting = NULL;
    if (widget == GTK_WIDGET(media_setting)) media_setting = NULL;
}
void peel_viewer_settings_attach(GtkBox *box) {
    GtkWidget *expander = gtk_expander_new("Viewer controls"); gtk_box_append(box, expander);
    GtkBox *rows = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)); gtk_expander_set_child(GTK_EXPANDER(expander), GTK_WIDGET(rows));
    volume_setting = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Show source mute and volume"));
    media_setting = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Show source previous, play/pause and next"));
    settings_updating = TRUE;
    gtk_check_button_set_active(volume_setting, g_atomic_int_get(&show_volume) != 0);
    gtk_check_button_set_active(media_setting, g_atomic_int_get(&show_media) != 0);
    settings_updating = FALSE;
    gtk_box_append(rows, GTK_WIDGET(volume_setting)); gtk_box_append(rows, GTK_WIDGET(media_setting));
    g_signal_connect(volume_setting, "toggled", G_CALLBACK(setting_toggled), NULL);
    g_signal_connect(media_setting, "toggled", G_CALLBACK(setting_toggled), NULL);
    g_signal_connect(volume_setting, "destroy", G_CALLBACK(setting_destroyed), NULL);
    g_signal_connect(media_setting, "destroy", G_CALLBACK(setting_destroyed), NULL);
    GtkWidget *note = gtk_label_new("Hiding a group only hides its buttons. Playback, the source and its permissions are unchanged.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE); gtk_label_set_xalign(GTK_LABEL(note), 0); gtk_widget_add_css_class(note, "dim-label");
    gtk_box_append(rows, note);
}
