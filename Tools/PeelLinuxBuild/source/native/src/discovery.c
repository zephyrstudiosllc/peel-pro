#include "internal.h"
#include <json-glib/json-glib.h>
#include <string.h>
/* No daemon autostart; all callbacks run on the initiating default context.
 * Each pending GIO callback owns one ref, including after cancel. */
typedef struct Registration {
    gatomicrefcount refs; uint64_t operation; PeelDiscoveryResult result; void *user;
    GDBusConnection *bus; char *owner,*path,*name,*type; GVariant *txt;
    uint16_t port; int interface_index,protocol; guint signal,owner_signal,timer,closed_signal; int pending; gboolean stopped,ready,failed,free_sent,close_sent,updating; GCancellable *cancel;
} Registration;
static GHashTable *registrations;
static Registration *ref(Registration *r) { g_atomic_ref_count_inc(&r->refs);return r; }
static void unref(Registration *r) { if(!g_atomic_ref_count_dec(&r->refs))return;g_clear_object(&r->bus);g_clear_object(&r->cancel);g_free(r->owner);g_free(r->path);g_free(r->name);g_free(r->type);g_variant_unref(r->txt);g_free(r); }
static void cleanup(Registration *r);
static void connection_closed(GObject *object,GAsyncResult *result,gpointer data) { Registration*r=data;GError*error=NULL;g_dbus_connection_close_finish(G_DBUS_CONNECTION(object),result,&error);g_clear_error(&error);r->pending--;cleanup(r);unref(r); }
static void fail(Registration *r) { ref(r);gboolean notify=!r->failed&&!r->stopped;r->failed=TRUE;r->stopped=TRUE;if(r->cancel)g_cancellable_cancel(r->cancel);if(notify&&r->result)r->result(r->operation,0,r->user);cleanup(r);unref(r); }
static void called(GObject *object,GAsyncResult *result,gpointer user);
typedef struct { Registration *r; int step; } Call;
static void call(Registration *r,int step,const char *path,const char *iface,const char *method,GVariant *args,const GVariantType *reply) {
    Call *c=g_new0(Call,1);c->r=ref(r);c->step=step;r->pending++;
    g_dbus_connection_call(r->bus,step == 0 ? "org.freedesktop.DBus" : r->owner,path,iface,method,args,reply,G_DBUS_CALL_FLAGS_NO_AUTO_START,5000,NULL,called,c);
}
static void cleanup(Registration *r) {
    if(!r->stopped||r->pending)return;
    if(r->timer){g_source_remove(r->timer);r->timer=0;}
    if(r->signal){g_dbus_connection_signal_unsubscribe(r->bus,r->signal);r->signal=0;}
    if(r->owner_signal){g_dbus_connection_signal_unsubscribe(r->bus,r->owner_signal);r->owner_signal=0;}
    if(r->closed_signal){g_signal_handler_disconnect(r->bus,r->closed_signal);r->closed_signal=0;}
    if(r->path&&!r->free_sent){r->free_sent=TRUE;call(r,5,r->path,"org.freedesktop.Avahi.EntryGroup","Free",NULL,G_VARIANT_TYPE_UNIT);return;}
    if(r->bus&&!g_dbus_connection_is_closed(r->bus)&&!r->close_sent){r->close_sent=TRUE;r->pending++;g_dbus_connection_close(r->bus,NULL,connection_closed,ref(r));return;}
    uint64_t op=r->operation;PeelDiscoveryResult result=r->result;void *user=r->user;r->result=NULL;
    /* Removing registry ref is safe: caller owns a callback or explicit ref. */
    g_hash_table_remove(registrations,&op);if(result)result(op,2,user);
}
static gboolean expired(gpointer user){Registration*r=user;r->timer=0;fail(r);return G_SOURCE_REMOVE;}
static void state(GDBusConnection *bus,const gchar *sender,const gchar *path,const gchar *iface,const gchar *signal,GVariant *args,gpointer user) {
    (void)bus;(void)path;(void)iface;(void)signal;Registration*r=user;int value;const char *error;
    if(r->stopped||g_strcmp0(sender,r->owner)||!g_variant_is_of_type(args,G_VARIANT_TYPE("(is)")))return;
    g_variant_get(args,"(i&s)",&value,&error);(void)error;
    if(value == 2&&!r->ready){r->ready=TRUE;if(r->timer){g_source_remove(r->timer);r->timer=0;}if(r->result)r->result(r->operation,1,r->user);}
    else if(value == 3||value == 4)fail(r);
}
static void owner_changed(GDBusConnection *bus,const gchar *sender,const gchar *path,const gchar *iface,const gchar *signal,GVariant *args,gpointer user) {
    (void)bus;(void)sender;(void)path;(void)iface;(void)signal;Registration*r=user;const char *name,*old,*next;
    if(!g_variant_is_of_type(args,G_VARIANT_TYPE("(sss)")))return;g_variant_get(args,"(&s&s&s)",&name,&old,&next);(void)old;
    if(!g_strcmp0(name,"org.freedesktop.Avahi")&&g_strcmp0(next,r->owner))fail(r);
}
static void called(GObject *object,GAsyncResult *result,gpointer user) {
    Call*c=user;Registration*r=c->r;GError*error=NULL;GVariant*v=g_dbus_connection_call_finish(G_DBUS_CONNECTION(object),result,&error);r->pending--;
    if(c->step == 2&&v){const char*p;g_variant_get(v,"(&o)",&p);r->path=g_strdup(p);} /* Even canceled creation must be freed. */
    if(c->step == 5){g_clear_pointer(&r->path,g_free);}
    else if(!v){fail(r);}
    else if(!r->stopped){
        switch(c->step){
        case 0:{const char*owner;g_variant_get(v,"(&s)",&owner);r->owner=g_strdup(owner);
            r->owner_signal=g_dbus_connection_signal_subscribe(r->bus,"org.freedesktop.DBus","org.freedesktop.DBus","NameOwnerChanged","/org/freedesktop/DBus","org.freedesktop.Avahi",G_DBUS_SIGNAL_FLAGS_NONE,owner_changed,r,NULL);
            call(r,1,"/","org.freedesktop.Avahi.Server","GetState",NULL,G_VARIANT_TYPE("(i)"));break;}
        case 1:{int value;g_variant_get(v,"(i)",&value);if(value!=2)fail(r);else call(r,2,"/","org.freedesktop.Avahi.Server","EntryGroupNew",NULL,G_VARIANT_TYPE("(o)"));break;}
        case 2:r->signal=g_dbus_connection_signal_subscribe(r->bus,r->owner,"org.freedesktop.Avahi.EntryGroup","StateChanged",r->path,NULL,G_DBUS_SIGNAL_FLAGS_NONE,state,r,NULL);
            call(r,3,r->path,"org.freedesktop.Avahi.EntryGroup","AddService",g_variant_new("(iiussssq@aay)",r->interface_index,r->protocol,0u,r->name,r->type,"local","",r->port,g_variant_ref(r->txt)),G_VARIANT_TYPE_UNIT);break;
        case 3:call(r,4,r->path,"org.freedesktop.Avahi.EntryGroup","Commit",NULL,G_VARIANT_TYPE_UNIT);break;
        default:break;
        }
    }
    if(v)g_variant_unref(v);g_clear_error(&error);cleanup(r);unref(r);g_free(c);
}
static void bus_closed(GDBusConnection *bus,gboolean remote,GError *error,gpointer data){(void)bus;(void)remote;(void)error;fail(data);}
static void connected(GObject *object,GAsyncResult *result,gpointer user) {
    (void)object;Registration*r=user;GError*error=NULL;r->bus=g_dbus_connection_new_for_address_finish(result,&error);r->pending--;
    if(r->bus)g_dbus_connection_set_exit_on_close(r->bus,FALSE);
    if(r->bus)r->closed_signal=g_signal_connect(r->bus,"closed",G_CALLBACK(bus_closed),r);
    if(!r->bus)fail(r);else if(!r->stopped)call(r,0,"/org/freedesktop/DBus","org.freedesktop.DBus","GetNameOwner",g_variant_new("(s)","org.freedesktop.Avahi"),G_VARIANT_TYPE("(s)"));
    g_clear_error(&error);cleanup(r);unref(r);
}
static void address_lookup(GTask *task,gpointer source,gpointer data,GCancellable *cancel) {
    (void)source;(void)data;GError*error=NULL;char*address=g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SYSTEM,cancel,&error);
    if(address)g_task_return_pointer(task,address,g_free);else g_task_return_error(task,error);
}
static void address_ready(GObject *object,GAsyncResult *result,gpointer data) {
    (void)object;Registration*r=data;GError*error=NULL;char*address=g_task_propagate_pointer(G_TASK(result),&error);r->pending--;
    if(!address)fail(r);else if(!r->stopped){r->pending++;g_dbus_connection_new_for_address(address,G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT|G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,NULL,r->cancel,connected,ref(r));}
    g_free(address);g_clear_error(&error);cleanup(r);unref(r);
}
static GVariant *read_txt(const char *txt_json) {
    JsonParser*parser=json_parser_new();GError*error=NULL;
    if(!json_parser_load_from_data(parser,txt_json,-1,&error)||!JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser))){g_clear_error(&error);g_object_unref(parser);return NULL;}
    JsonObject*obj=json_node_get_object(json_parser_get_root(parser));GList*keys=json_object_get_members(obj);GVariantBuilder builder;g_variant_builder_init(&builder,G_VARIANT_TYPE("aay"));gboolean valid=g_list_length(keys)<=6;
    for(GList*i=keys;valid&&i;i=i->next){const char*key=i->data;JsonNode*node=json_object_get_member(obj,key);const char*value=JSON_NODE_HOLDS_VALUE(node)&&json_node_get_value_type(node)==G_TYPE_STRING?json_node_get_string(node):NULL;
        if((strcmp(key,"hostId")&&strcmp(key,"pairMode")&&strcmp(key,"pinSalt")&&strcmp(key,"pinExp")&&strcmp(key,"pairPort")&&strcmp(key,"tlsPSKOrder"))||!value||strchr(key,'=')||strlen(key)+strlen(value)+1>255||!g_utf8_validate(value,-1,NULL)){valid=FALSE;break;}
        char*entry=g_strdup_printf("%s=%s",key,value);g_variant_builder_add_value(&builder,g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE,entry,strlen(entry),1));g_free(entry);
    }
    g_list_free(keys);g_object_unref(parser);if(!valid){g_variant_builder_clear(&builder);return NULL;}
    return g_variant_ref_sink(g_variant_builder_end(&builder));
}
int peel_linux_discovery_publish(uint64_t operation,const char *name,const char *type,uint16_t port,int interface_index,int protocol,const char *txt_json,PeelDiscoveryResult result,void *user) {
    if(!g_main_context_is_owner(g_main_context_default())||!operation||!result||!name||!strlen(name)||strlen(name)>63||!g_utf8_validate(name,-1,NULL)||!type||(strcmp(type,"_peel._tcp")&&strcmp(type,"_peelpair._tcp"))||!port||interface_index < -1 || (protocol != -1 && protocol != 0 && protocol != 1)||!txt_json||strlen(txt_json)>4096)return 0;
    if(!registrations)registrations=g_hash_table_new_full(g_int64_hash,g_int64_equal,g_free,(GDestroyNotify)unref);
    if(g_hash_table_contains(registrations,&operation)||g_hash_table_size(registrations)>=8)return 0;
    GVariant*txt=read_txt(txt_json);if(!txt)return 0;
    Registration*r=g_new0(Registration,1);g_atomic_ref_count_init(&r->refs);r->operation=operation;r->result=result;r->user=user;r->name=g_strdup(name);r->type=g_strdup(type);r->port=port;r->interface_index=interface_index;r->protocol=protocol;r->txt=txt;uint64_t*k=g_new(uint64_t,1);*k=operation;g_hash_table_insert(registrations,k,r);
    r->timer=g_timeout_add_seconds_full(G_PRIORITY_DEFAULT,15,expired,ref(r),(GDestroyNotify)unref);r->cancel=g_cancellable_new();r->pending++;GTask*lookup=g_task_new(NULL,r->cancel,address_ready,ref(r));g_task_run_in_thread(lookup,address_lookup);g_object_unref(lookup);return 1;
}
void peel_linux_discovery_stop(uint64_t operation){if(!g_main_context_is_owner(g_main_context_default())||!registrations)return;Registration*r=g_hash_table_lookup(registrations,&operation);if(r){ref(r);r->stopped=TRUE;g_cancellable_cancel(r->cancel);cleanup(r);unref(r);}}

/* TXT update keeps the existing serving control group. An uncertain outcome is
 * returned to managed code, which must restore old exact TXT or declare Lost. */
typedef struct { Registration *r; uint64_t transaction; GVariant *txt; PeelDiscoveryResult callback; void *user; int phase; } Update;
static void updated(GObject *object,GAsyncResult *result,gpointer data) {
    Update*u=data;Registration*r=u->r;GError*error=NULL;GVariant*v=g_dbus_connection_call_finish(G_DBUS_CONNECTION(object),result,&error);r->pending--;
    gboolean ok=v&&!r->stopped;
    if(ok&&u->phase==0){g_variant_unref(v);u->phase=1;r->pending++;g_dbus_connection_call(r->bus,r->owner,r->path,"org.freedesktop.Avahi.EntryGroup","GetState",NULL,G_VARIANT_TYPE("(i)"),G_DBUS_CALL_FLAGS_NO_AUTO_START,5000,NULL,updated,u);return;}
    if(ok){int state;g_variant_get(v,"(i)",&state);ok=state==2;}
    if(ok){g_variant_unref(r->txt);r->txt=g_variant_ref(u->txt);}
    if(v)g_variant_unref(v);g_clear_error(&error);r->updating=FALSE;u->callback(u->transaction,ok?1:0,u->user);g_variant_unref(u->txt);cleanup(r);unref(r);g_free(u);
}
int peel_linux_discovery_update(uint64_t operation,uint64_t transaction,const char *txt_json,PeelDiscoveryResult callback,void *user) {
    if(!g_main_context_is_owner(g_main_context_default())||!registrations||!transaction||!callback||!txt_json||strlen(txt_json)>4096)return 0;
    Registration*r=g_hash_table_lookup(registrations,&operation);if(!r||r->stopped||!r->ready||!r->path||r->updating)return 0;
    GVariant*txt=read_txt(txt_json);if(!txt)return 0;
    Update*u=g_new0(Update,1);u->r=ref(r);u->transaction=transaction;u->txt=txt;u->callback=callback;u->user=user;r->pending++;r->updating=TRUE;
    g_dbus_connection_call(r->bus,r->owner,r->path,"org.freedesktop.Avahi.EntryGroup","UpdateServiceTxt",g_variant_new("(iiusss@aay)",r->interface_index,r->protocol,0u,r->name,r->type,"local",g_variant_ref(txt)),G_VARIANT_TYPE_UNIT,G_DBUS_CALL_FLAGS_NO_AUTO_START,5000,NULL,updated,u);return 1;
}
