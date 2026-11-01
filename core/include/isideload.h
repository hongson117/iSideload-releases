// iSideload core C ABI. MIT License.
#ifndef ISIDELOAD_H
#define ISIDELOAD_H
#include <stddef.h>
#include <stdint.h>

/* Progress event, JSON: {"stage":"…","progress":0.0-1.0|null} */
typedef void (*isl_event_cb)(void *ctx, const char *json);
/* Blocking question, JSON: {"kind":"2fa"|"revoke"|"appids",…}. Write answer into out; return 0 = answered, non-zero = cancel. */
typedef int32_t (*isl_prompt_cb)(void *ctx, const char *json, char *out, size_t cap);

/* Runs one request (JSON with "op"). Returns {"ok":true,…} or {"ok":false,"error":"…","hint":"…"}; free with isl_string_free. */
char *isl_call(const char *request_json, isl_event_cb event, isl_prompt_cb prompt, void *ctx);
void isl_string_free(char *s);

#endif
