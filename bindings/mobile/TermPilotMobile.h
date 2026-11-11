#ifndef TERMPILOT_MOBILE_H
#define TERMPILOT_MOBILE_H
#include <stdint.h>
#include <stddef.h>
// Calls never retain client pointers. Returned buffers must be freed once.
// JSON responses are UTF-8; poll returns [4-byte BE JSON length][JSON][payload].
// The 32-byte vault key comes from Keychain / Android Keystore, never a key file.
uint64_t tp_mobile_create(const char *directory, const uint8_t *key, size_t key_length);
char *tp_mobile_call(uint64_t runtime, const uint8_t *json, size_t length);
uint8_t *tp_mobile_poll(uint64_t runtime, uint32_t timeout_ms, size_t *length);
void tp_mobile_free_string(char *value);
void tp_mobile_free_buffer(uint8_t *value, size_t length);
void tp_mobile_destroy(uint64_t runtime);
#endif
