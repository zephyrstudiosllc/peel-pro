#pragma once
#include "peel_linux.h"
#include <gtk/gtk.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/video/video.h>
typedef struct PeelSurface PeelSurface;
PeelSurface *peel_surface_new(const char *title);
void peel_surface_sample(PeelSurface *surface, GstSample *sample);
void peel_surface_close(PeelSurface *surface);
PeelSurface *peel_surface_ref(PeelSurface *surface);
void peel_surface_unref(PeelSurface *surface);
/* GLib main thread only; pipeline source owns supplied restricted fd for its
 * lifetime, caller closes its own copy after state NULL. No default PW remote. */
void peel_host_choose(GtkWindow *parent, gboolean request_control);
void peel_host_stop(void);

void peel_ui_video_closed(uint32_t window, uint64_t generation);
gboolean peel_receiver_current(uint64_t generation); /* any thread */
GtkWidget *peel_viewer_controls_new(uint64_t generation, uint32_t window); /* GTK main only */
void peel_viewer_settings_attach(GtkBox *box); /* GTK main only */
void peel_audio_test_sink(const char *description); /* tests only: replaces autoaudiosink */
gboolean peel_audio_sink_is_real(GstElement *sink); /* after READY: selected subtree has a real audio sink, no fakesink */
/* Registry-metadata-only output selection (no element is opened). Production
 * uses autoaudiosink when installed, else the first qualified exact fallback
 * (pipewiresink, then alsasink). NULL means no output backend. */
gboolean peel_audio_factory_accepts_pcm(GstElementFactory *factory); /* some sink pad template intersects audio/x-raw */
gboolean peel_audio_factory_qualified(GstElementFactory *factory); /* allowlisted name + Sink class + raw-audio sink pad */
const char *peel_audio_fallback_choice(void); /* first qualified fallback, ignoring autoaudiosink */
const char *peel_audio_output_choice(void); /* what production tries first */
void peel_share_status(const char *message); /* Share tab; any thread, like peel_linux_status */
char *peel_ui_window_title(uint32_t window, uint64_t generation); /* GTK main only; g_free */

void peel_host_ui_attach(GtkWindow *parent, GtkBox *box);
void peel_host_ui_activated(void);
gboolean peel_host_ui_preclose(void);
gboolean peel_host_ui_registered(void);
void peel_host_ui_detach(void);
void peel_ui_finish_close(void);
