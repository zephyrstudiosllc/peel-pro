#include "peel_linux.h"
#include <libsecret/secret.h>
#include <string.h>
static const SecretSchema schema = {
    "com.zephyrstudiosllc.Peel.Pairing", SECRET_SCHEMA_NONE,
    { { "stable-host-id", SECRET_SCHEMA_ATTRIBUTE_STRING }, { NULL, 0 } }
};
char *peel_linux_secret_lookup(const char *id) {
    if (!id || !*id || strlen(id) > 1024) return NULL;
    GError *error = NULL;
    char *value = secret_password_lookup_sync(&schema, NULL, &error, "stable-host-id", id, NULL);
    if (error) { g_error_free(error); if (value) secret_password_free(value); return NULL; }
    if (value && strlen(value) > 4096) { secret_password_free(value); return NULL; }
    return value;
}
int peel_linux_secret_store(const char *id, const char *secret) {
    if (!id || !*id || strlen(id) > 1024 || !secret || !*secret || strlen(secret) > 4096) return 0;
    GError *error = NULL;
    gboolean ok = secret_password_store_sync(&schema, SECRET_COLLECTION_DEFAULT,
        "Peel Pro paired computer", secret, NULL, &error, "stable-host-id", id, NULL);
    if (error) { g_error_free(error); return 0; }
    return ok;
}
void peel_linux_secret_free(char *secret) { if (secret) secret_password_free(secret); }
