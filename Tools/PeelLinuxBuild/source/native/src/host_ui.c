#include "internal.h"
#include <string.h>
/* All state and callbacks belong to the default GTK context. */
static struct {
    PeelHostUIEvent event; PeelHostUIAnswer answer; void *user;
    GtkWindow *parent, *modal; GtkLabel *status; GtkWidget *pair, *share, *stop;
    uint64_t epoch, operation, revision; int kind; gboolean closing, approved;
} ui;
static gboolean main_context(void) { return g_main_context_is_owner(g_main_context_default()); }
static gboolean text(const char *s, size_t max) { return s && strlen(s) <= max && g_utf8_validate(s,-1,NULL); }
static void answer(int value) { if (ui.answer && ui.operation) ui.answer(ui.operation,value,ui.user); }
static void drop_modal(gboolean cancel) {
    GtkWindow *old = ui.modal; uint64_t op = ui.operation;
    int result = ui.approved ? 2 : 0;
    ui.modal = NULL; ui.operation = 0; ui.kind = 0; ui.approved = FALSE;
    if (old) { g_signal_handlers_disconnect_by_data(old,&ui); gtk_window_destroy(old); g_object_unref(old); }
    if (cancel && op && ui.answer) ui.answer(op,result,ui.user);
}
static gboolean modal_closed(GtkWindow *window, gpointer data) { (void)window;(void)data; drop_modal(TRUE);return TRUE; }
static void cancel_clicked(GtkButton *button,gpointer data) { (void)button;(void)data;drop_modal(TRUE); }
static void approved(GtkButton *button,gpointer data) {
    (void)data; if (!ui.modal || ui.kind != 2 || ui.approved || ui.closing) return;
    ui.approved = TRUE; gtk_widget_set_sensitive(GTK_WIDGET(button),FALSE); answer(1); drop_modal(FALSE);
}
static void mapped(GtkWidget *window,gpointer data) {
    (void)data; if (ui.modal == GTK_WINDOW(window) && ui.kind == 1 && !ui.approved && !ui.closing) { ui.approved = TRUE; answer(1); }
}
static void action(GtkButton *button,gpointer data) { (void)button; if (!ui.closing && ui.event) { int kind=GPOINTER_TO_INT(data);if(kind==4){peel_host_stop();peel_share_status("Sharing stopped. No source remains granted.");}ui.event(kind,ui.epoch,ui.user); } }
void peel_linux_host_ui_register(PeelHostUIEvent event,PeelHostUIAnswer response,void *user) {
    /* Before run only; replacing active callbacks would break delegate lifetime. */
    if (ui.parent) return; ui.event = event; ui.answer = response; ui.user = user;
}
void peel_host_ui_attach(GtkWindow *parent,GtkBox *box) {
    ui.parent = parent; ui.closing = FALSE; ui.revision=0; ui.epoch++; if (!ui.epoch) ui.epoch++;
    if (!ui.event) return;
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL,8);
    ui.pair = gtk_button_new_with_label("Pair a device");ui.share = gtk_button_new_with_label("Share selected source");ui.stop = gtk_button_new_with_label("Stop sharing");
    gtk_box_append(GTK_BOX(row),ui.pair);gtk_box_append(GTK_BOX(row),ui.share);gtk_box_append(GTK_BOX(row),ui.stop);gtk_box_append(box,row);
    g_signal_connect(ui.pair,"clicked",G_CALLBACK(action),GINT_TO_POINTER(2));g_signal_connect(ui.share,"clicked",G_CALLBACK(action),GINT_TO_POINTER(3));g_signal_connect(ui.stop,"clicked",G_CALLBACK(action),GINT_TO_POINTER(4));
    gtk_widget_set_tooltip_text(ui.pair,"Show a six-digit code to enter on the other device. Available when this computer is ready and idle.");
    gtk_widget_set_tooltip_text(ui.share,"Confirm, then let paired devices view the chosen source. Needs a chosen source and at least one paired device.");
    gtk_widget_set_tooltip_text(ui.stop,"Stop sharing and pairing, release the source and stop advertising this computer.");
    gtk_widget_set_sensitive(ui.pair,FALSE);gtk_widget_set_sensitive(ui.share,FALSE);gtk_widget_set_sensitive(ui.stop,FALSE);
    ui.status = GTK_LABEL(gtk_label_new("Preparing this computer…"));gtk_label_set_wrap(ui.status,TRUE);gtk_box_append(box,GTK_WIDGET(ui.status));
}
void peel_host_ui_activated(void) { if (ui.event && ui.parent && !ui.closing) ui.event(1,ui.epoch,ui.user); }
void peel_linux_host_ui_state(uint64_t epoch,uint64_t revision,const char *message,int can_pair,int can_share,int can_stop) {
    if (!main_context() || epoch != ui.epoch || revision < ui.revision || !ui.parent || !text(message,1024)) return;
    ui.revision=revision; if (ui.status) gtk_label_set_text(ui.status,message);
    if (ui.closing) return;
    if (ui.pair) gtk_widget_set_sensitive(ui.pair,can_pair == 1);
    if (ui.share) gtk_widget_set_sensitive(ui.share,can_share == 1);
    if (ui.stop) gtk_widget_set_sensitive(ui.stop,can_stop == 1);
}
int peel_linux_host_ui_present(uint64_t epoch,uint64_t operation,int kind,const char *name,const char *detail) {
    if (!main_context() || !ui.parent || ui.closing || epoch != ui.epoch || !operation || ui.modal || (kind != 1 && kind != 2) || !text(name,256) || !text(detail,1024)) return 0;
    ui.modal = GTK_WINDOW(gtk_window_new());g_object_ref_sink(ui.modal);ui.operation=operation;ui.kind=kind;ui.approved=FALSE;
    gtk_window_set_title(ui.modal,kind == 1 ? "Pair a device" : "Share selected source");gtk_window_set_transient_for(ui.modal,ui.parent);gtk_window_set_modal(ui.modal,TRUE);gtk_window_set_default_size(ui.modal,360,200);
    GtkBox *box=GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL,12));gtk_widget_set_margin_start(GTK_WIDGET(box),20);gtk_widget_set_margin_end(GTK_WIDGET(box),20);gtk_widget_set_margin_top(GTK_WIDGET(box),20);gtk_widget_set_margin_bottom(GTK_WIDGET(box),20);gtk_window_set_child(ui.modal,GTK_WIDGET(box));
    GtkWidget *label=gtk_label_new(name);gtk_label_set_wrap(GTK_LABEL(label),TRUE);gtk_box_append(box,label);
    label=gtk_label_new(detail);gtk_label_set_wrap(GTK_LABEL(label),TRUE);gtk_label_set_selectable(GTK_LABEL(label),kind == 1);gtk_box_append(box,label);
    if (kind == 2) { GtkWidget *yes=gtk_button_new_with_label("Share");gtk_box_append(box,yes);g_signal_connect(yes,"clicked",G_CALLBACK(approved),NULL); }
    GtkWidget *cancel=gtk_button_new_with_label(kind == 1 ? "Cancel" : "Stop sharing");gtk_box_append(box,cancel);g_signal_connect(cancel,"clicked",G_CALLBACK(cancel_clicked),NULL);
    g_signal_connect(ui.modal,"close-request",G_CALLBACK(modal_closed),&ui);g_signal_connect(ui.modal,"map",G_CALLBACK(mapped),&ui);gtk_window_present(ui.modal);return 1;
}
void peel_linux_host_ui_dismiss(uint64_t epoch,uint64_t operation) { if (main_context() && epoch == ui.epoch && operation == ui.operation) drop_modal(FALSE); }
gboolean peel_host_ui_preclose(void) {
    if (!ui.event) return FALSE;
    if (!ui.closing) { ui.closing=TRUE; if(ui.pair)gtk_widget_set_sensitive(ui.pair,FALSE);if(ui.share)gtk_widget_set_sensitive(ui.share,FALSE);if(ui.stop)gtk_widget_set_sensitive(ui.stop,FALSE);drop_modal(TRUE); if(ui.status)gtk_label_set_text(ui.status,"Disconnecting…");ui.event(5,ui.epoch,ui.user); }
    return TRUE;
}
void peel_linux_host_ui_finish_close(uint64_t epoch) { if (main_context() && ui.closing && epoch == ui.epoch) peel_ui_finish_close(); }
void peel_host_ui_detach(void) { drop_modal(FALSE);ui.parent=NULL;ui.status=NULL;ui.pair=ui.share=ui.stop=NULL;ui.event=NULL;ui.answer=NULL;ui.user=NULL; }

gboolean peel_host_ui_registered(void) { return ui.event != NULL; }
