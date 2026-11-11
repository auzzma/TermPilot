#ifndef TERMPILOT_CORE_H
#define TERMPILOT_CORE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
uint32_t tp_core_api_version(void);
/* Input is borrowed UTF-8 JSON. Returned UTF-8 JSON is freed with tp_core_free.
   Thread-safe. No callback or UI thread requirement. Do not log requests. */
char *tp_core_call(const uint8_t *data, size_t length);
void tp_core_free(char *value);
#ifdef __cplusplus
}
#endif
#endif

