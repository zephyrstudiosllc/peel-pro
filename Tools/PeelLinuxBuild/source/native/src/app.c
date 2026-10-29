#include "internal.h"
#include <json-glib/json-glib.h>
#include <string.h>
static struct {
    GtkApplication *application;
    GtkWindow *window;
    GtkLabel *status, *share_status;
    GtkWidget *windows_empty;
    GtkEntry *stable_id, *address;
    GtkSpinButton *port;
    GtkListBox *windows;
    PeelConnect connect;
    PeelOpenWindow open_window;
    PeelDisconnect disconnect;
    PeelCloseWindow close_window;
    void *user;
    gboolean closing;
} app;
static gboolean show_status(gpointer data) {
    if (!app.closing && app.status) gtk_label_set_text(app.status, data);
    return G_SOURCE_REMOVE;
}
void peel_linux_status(const char *text) {
    if (!text || strlen(text) > 4096 || !g_utf8_validate(text, -1, NULL)) return;
    g_idle_add_full(G_PRIORITY_DEFAULT, show_status, g_strdup(text), g_free);
}
/* Local source/portal messages belong to Share; receiver messages stay on Connect. */
static gboolean show_share_status(gpointer data) {
    if (!app.closing && app.share_status) gtk_label_set_text(app.share_status, data);
    return G_SOURCE_REMOVE;
}
void peel_share_status(const char *text) {
    if (!text || strlen(text) > 4096 || !g_utf8_validate(text, -1, NULL)) return;
    g_idle_add_full(G_PRIORITY_DEFAULT, show_share_status, g_strdup(text), g_free);
}
typedef struct { char *json; guint64 generation; } WindowRows;
static guint64 rendered_generation;
static void free_rows(gpointer data) { WindowRows *rows = data; g_free(rows->json); g_free(rows); }
static gboolean show_windows(gpointer data) {
    WindowRows *rows = data;
    if (rows->generation < rendered_generation) return G_SOURCE_REMOVE;
    rendered_generation = rows->generation;
    if (app.closing || !app.windows) return G_SOURCE_REMOVE;
    JsonParser *parser = json_parser_new();
    if (!json_parser_load_from_data(parser, rows->json, -1, NULL) || !JSON_NODE_HOLDS_ARRAY(json_parser_get_root(parser))) { g_object_unref(parser); return G_SOURCE_REMOVE; }
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(app.windows)))) gtk_list_box_remove(app.windows, child);
    JsonArray *array = json_node_get_array(json_parser_get_root(parser));
    guint count = json_array_get_length(array), shown = 0;
    if (count > 4096) { if (app.windows_empty) gtk_widget_set_visible(app.windows_empty, TRUE); g_object_unref(parser); return G_SOURCE_REMOVE; }
    for (guint i = 0; i < count; i++) {
        JsonObject *row = json_array_get_object_element(array, i);
        if (!row || !json_object_has_member(row, "id") || !json_object_has_member(row, "title")) continue;
        gint64 id = json_object_get_int_member(row, "id"); const char *title = json_object_get_string_member(row, "title");
        if (id < 1 || id > UINT32_MAX || !title || strlen(title) > 4096) continue;
        GtkWidget *item = gtk_list_box_row_new(), *label = gtk_label_new(title);
        gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(item), label); g_object_set_data(G_OBJECT(item), "window-id", GUINT_TO_POINTER((guint)id));
        g_object_set_data_full(G_OBJECT(item), "session-generation", g_memdup2(&rows->generation, sizeof(rows->generation)), g_free);
        gtk_list_box_append(app.windows, item); shown++;
    }
    if (app.windows_empty) gtk_widget_set_visible(app.windows_empty, shown == 0);
    g_object_unref(parser); return G_SOURCE_REMOVE;
}
/* GTK main only. Names a viewer after its exact current row; NULL if gone. */
char *peel_ui_window_title(uint32_t window, uint64_t generation) {
    if (app.closing || !app.windows || !window) return NULL;
    for (GtkWidget *row = gtk_widget_get_first_child(GTK_WIDGET(app.windows)); row; row = gtk_widget_get_next_sibling(row)) {
        guint64 *shown = GTK_IS_LIST_BOX_ROW(row) ? g_object_get_data(G_OBJECT(row), "session-generation") : NULL;
        GtkWidget *label = shown ? gtk_list_box_row_get_child(GTK_LIST_BOX_ROW(row)) : NULL;
        if (shown && *shown == generation && GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(row), "window-id")) == window && GTK_IS_LABEL(label))
            return g_strdup(gtk_label_get_text(GTK_LABEL(label)));
    }
    return NULL;
}
void peel_linux_windows(const char *json, uint64_t generation) {
    if (!json || strlen(json) > 262144 || !g_utf8_validate(json, -1, NULL)) return;
    WindowRows *rows = g_new0(WindowRows, 1); rows->json = g_strdup(json); rows->generation = generation;
    g_idle_add_full(G_PRIORITY_DEFAULT, show_windows, rows, free_rows);
}
static void choose(GtkButton *button, gpointer unused) { (void)button; (void)unused; if (app.closing || !app.window) return; peel_host_choose(app.window, FALSE); }
static void stop_share(GtkButton *button, gpointer unused) { (void)button; (void)unused; peel_host_stop(); peel_share_status("Sharing stopped. No source remains granted."); }
static void connect_computer(GtkButton *button, gpointer unused) {
    (void)button; (void)unused;
    if (app.connect) app.connect(gtk_editable_get_text(GTK_EDITABLE(app.stable_id)), gtk_editable_get_text(GTK_EDITABLE(app.address)), gtk_spin_button_get_value_as_int(app.port), app.user);
}
static void disconnect_computer(GtkButton *button, gpointer unused) { (void)button; (void)unused; if (app.disconnect) app.disconnect(app.user); }
static void open_window(GtkListBox *list, GtkListBoxRow *row, gpointer unused) {
    (void)list; (void)unused;
    guint64 *generation = row ? g_object_get_data(G_OBJECT(row), "session-generation") : NULL;
    if (generation && app.open_window) app.open_window(GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(row), "window-id")), *generation, app.user);
}
static gboolean close_main(GtkWindow *window, gpointer unused) {
    (void)window; (void)unused; app.closing = TRUE;
    peel_host_stop(); if (app.disconnect) app.disconnect(app.user); return peel_host_ui_preclose();
}
static GtkEntry *entry(GtkGrid *grid, int row, const char *name, const char *placeholder) {
    GtkWidget *label = gtk_label_new(name); gtk_label_set_xalign(GTK_LABEL(label), 0); gtk_grid_attach(grid, label, 0, row, 1, 1);
    GtkEntry *e = GTK_ENTRY(gtk_entry_new()); gtk_entry_set_placeholder_text(e, placeholder);
    gtk_entry_set_max_length(e, 1024); gtk_widget_set_hexpand(GTK_WIDGET(e), TRUE); gtk_grid_attach(grid, GTK_WIDGET(e), 1, row, 1, 1); return e;
}
static GtkWidget *note(GtkBox *box, const char *text, const char *style) {
    GtkWidget *label = gtk_label_new(text); gtk_label_set_wrap(GTK_LABEL(label), TRUE); gtk_label_set_xalign(GTK_LABEL(label), 0);
    if (style) gtk_widget_add_css_class(label, style);
    gtk_box_append(box, label); return label;
}
static GtkBox *page(GtkStack *stack, const char *name, const char *title) {
    GtkBox *box = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)); gtk_widget_set_margin_top(GTK_WIDGET(box), 12);
    gtk_stack_add_titled(stack, GTK_WIDGET(box), name, title); return box;
}
static void activate(GtkApplication *application, gpointer unused) {
    (void)unused;
    if (app.window) { gtk_window_present(app.window); return; }
    app.window = GTK_WINDOW(gtk_application_window_new(application)); gtk_window_set_title(app.window, "Peel Pro");
    gtk_window_set_default_size(app.window, 640, 680); g_signal_connect(app.window, "close-request", G_CALLBACK(close_main), NULL);
    GtkBox *box = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 10));
    gtk_widget_set_margin_start(GTK_WIDGET(box), 18); gtk_widget_set_margin_end(GTK_WIDGET(box), 18);
    gtk_widget_set_margin_top(GTK_WIDGET(box), 18); gtk_widget_set_margin_bottom(GTK_WIDGET(box), 18);
    gtk_window_set_child(app.window, GTK_WIDGET(box));
    note(box, "Remote Desktop", "title-2");
    GtkStack *stack = GTK_STACK(gtk_stack_new()); gtk_widget_set_vexpand(GTK_WIDGET(stack), TRUE);
    GtkWidget *tabs = gtk_stack_switcher_new(); gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(tabs), stack);
    gtk_widget_set_halign(tabs, GTK_ALIGN_START); gtk_box_append(box, tabs); gtk_box_append(box, GTK_WIDGET(stack));

    /* Connect: the existing saved-pairing client and its window list. */
    GtkBox *connect_page = page(stack, "connect", "Connect");
    note(connect_page, "Open desktops and app windows from a computer you already paired: Mac, Windows or Linux.", NULL);
    note(connect_page, "Paired computer", "heading");
    GtkGrid *saved = GTK_GRID(gtk_grid_new()); gtk_grid_set_row_spacing(saved, 8); gtk_grid_set_column_spacing(saved, 12); gtk_box_append(connect_page, GTK_WIDGET(saved));
    app.stable_id = entry(saved, 0, "Computer ID", "Stable ID saved when you paired"); app.address = entry(saved, 1, "Address", "Private-network or VPN address");
    GtkWidget *port_label = gtk_label_new("Streaming port"); gtk_label_set_xalign(GTK_LABEL(port_label), 0); gtk_grid_attach(saved, port_label, 0, 2, 1, 1);
    app.port = GTK_SPIN_BUTTON(gtk_spin_button_new_with_range(1, 65535, 1)); gtk_spin_button_set_value(app.port, 54321); gtk_widget_set_halign(GTK_WIDGET(app.port), GTK_ALIGN_START); gtk_grid_attach(saved, GTK_WIDGET(app.port), 1, 2, 1, 1);
    GtkBox *actions = GTK_BOX(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)); gtk_box_append(connect_page, GTK_WIDGET(actions));
    GtkWidget *connect = gtk_button_new_with_label("Connect"); gtk_widget_set_sensitive(connect, app.connect != NULL);
    gtk_widget_set_tooltip_text(connect, app.connect ? "Connect with the pairing saved in Secret Service. Replaces any current connection." : "Unavailable: this native preview has no network client.");
    gtk_box_append(actions, connect); g_signal_connect(connect, "clicked", G_CALLBACK(connect_computer), NULL);
    GtkWidget *disconnect = gtk_button_new_with_label("Disconnect"); gtk_widget_set_tooltip_text(disconnect, "Close the connection and any open viewer window.");
    gtk_box_append(actions, disconnect); g_signal_connect(disconnect, "clicked", G_CALLBACK(disconnect_computer), NULL);
    app.status = GTK_LABEL(note(connect_page, app.connect ? "Not connected. Enter a paired computer, then Connect." : "Native capture preview. Managed TLS client is not loaded.", NULL));
    note(connect_page, "Windows on the connected computer", "heading");
    app.windows_empty = note(connect_page, "No windows yet. Connect to list the desktops and app windows that computer shares.", "dim-label");
    GtkWidget *scroll = gtk_scrolled_window_new(); gtk_widget_set_vexpand(scroll, TRUE); gtk_box_append(connect_page, scroll);
    app.windows = GTK_LIST_BOX(gtk_list_box_new()); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(app.windows));
    g_signal_connect(app.windows, "row-activated", G_CALLBACK(open_window), NULL);
    note(connect_page, "Select a window to open it in its own viewer. One window streams at a time: opening another replaces it, and closing the viewer stops it. When the source shares audio and this computer has a working audio output, its sound plays here; Listen in the viewer turns it off for that computer. The viewer's media and volume buttons act on the source computer only when it offers them. Keyboard, pointer and clipboard are not sent.", "dim-label");
    peel_viewer_settings_attach(connect_page);
    GtkWidget *pair_help = gtk_expander_new("Pair with another computer"); gtk_box_append(connect_page, pair_help);
    GtkBox *steps = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)); gtk_expander_set_child(GTK_EXPANDER(pair_help), GTK_WIDGET(steps));
    note(steps, "Pairing runs in a terminal so the six-digit code is never stored, logged or passed on the command line.", NULL);
    note(steps, "1. On the other computer, start pairing in Peel so it shows a code.\n2. Read its address, hostId, pairPort and pinSalt from its pairing advertisement, for example:", NULL);
    GtkWidget *browse = note(steps, "avahi-browse -rt _peelpair._tcp", "monospace"); gtk_label_set_selectable(GTK_LABEL(browse), TRUE);
    note(steps, "3. From the Peel Pro folder, run this and type the code at its prompt:", NULL);
    GtkWidget *command = note(steps, "./peel-pro --pair ADDRESS PAIR_PORT HOST_ID PIN_SALT", "monospace"); gtk_label_set_selectable(GTK_LABEL(command), TRUE);
    note(steps, "4. Enter the same computer ID, its private-network or VPN address and its streaming port above.", NULL);

    /* Share This Computer: local portal source plus the registered host UI. */
    GtkBox *share_page = page(stack, "share", "Share This Computer");
    note(share_page, "Let devices you paired view one screen or window from this computer.", NULL);
    note(share_page, "Source · This computer (Linux)", "heading");
    GtkBox *source = GTK_BOX(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)); gtk_box_append(share_page, GTK_WIDGET(source));
    GtkWidget *choose_button = gtk_button_new_with_label("Choose source"); gtk_box_append(source, choose_button);
    gtk_widget_set_tooltip_text(choose_button, "Your desktop asks which screen or window to share. Choosing again ends the current source.");
    g_signal_connect(choose_button, "clicked", G_CALLBACK(choose), NULL);
    if (!peel_host_ui_registered()) { GtkWidget *stop = gtk_button_new_with_label("Stop sharing"); gtk_box_append(source, stop); g_signal_connect(stop, "clicked", G_CALLBACK(stop_share), NULL); }
    app.share_status = GTK_LABEL(note(share_page, "No source chosen. Nothing is shared until you choose one.", NULL));
    if (peel_host_ui_registered()) note(share_page, "Paired devices", "heading");
    peel_host_ui_attach(app.window, share_page);
    note(share_page, peel_host_ui_registered()
        ? "A local preview opens for the chosen source; closing it stops sharing. Paired devices can view only; their keyboard and pointer input is refused, and audio and clipboard are not shared."
        : "A local preview opens for the chosen source; closing it stops sharing. This preview build cannot share over the network.", "dim-label");
    gtk_window_present(app.window); peel_host_ui_activated();
}
void peel_ui_video_closed(uint32_t window, uint64_t generation) {
    if (!app.closing && app.close_window) app.close_window(window, generation, app.user);
}
int peel_linux_run(PeelConnect connect, PeelOpenWindow open, PeelDisconnect disconnect, PeelCloseWindow close_window, void *user) {
    gst_init(NULL, NULL);
    app.connect = connect; app.open_window = open; app.disconnect = disconnect; app.close_window = close_window; app.user = user; app.closing = FALSE;
    app.application = gtk_application_new("com.zephyrstudiosllc.Peel.Linux", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app.application, "activate", G_CALLBACK(activate), NULL);
    int code = g_application_run(G_APPLICATION(app.application), 0, NULL);
    app.closing = TRUE; peel_host_stop(); if (app.disconnect) app.disconnect(app.user);
    peel_host_ui_detach(); g_clear_object(&app.application); app.window = NULL; app.status = NULL; app.share_status = NULL; app.windows = NULL; app.windows_empty = NULL;
    return code;
}

void peel_ui_finish_close(void) { if (app.closing && app.application) { if (app.window) { GtkWindow *window=app.window;app.window=NULL;gtk_window_destroy(window); } g_application_quit(G_APPLICATION(app.application)); } }
