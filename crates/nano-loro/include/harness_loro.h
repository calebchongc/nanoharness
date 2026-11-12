#ifndef HARNESS_LORO_H
#define HARNESS_LORO_H
#include <stdint.h>
#include <stddef.h>
/* Project-owned C ABI, not upstream UniFFI. No allocation crosses allocators.
 * A handle has one owner and MUST be serialized externally. Do not call after
 * free. Every returned buffer (including errors) is freed exactly once here.
 * All functions catch Rust panics. Invalid non-null pointers remain caller UB.
 * Input spans are borrowed only for the duration of a call; max 128 MiB.
 * Return: 0 success, 1 causally pending (import/pending-query), <0 error.
 * Error buffer is UTF-8; successful buffers follow the operation below. */
typedef struct HarnessLoro HarnessLoro;
typedef struct { uint8_t *ptr; size_t len; } HarnessLoroBuffer;
int32_t harness_loro_new(const uint8_t *, size_t, HarnessLoro **, HarnessLoroBuffer *);
int32_t harness_loro_call(HarnessLoro *, uint32_t, const uint8_t *, size_t, HarnessLoroBuffer *);
void harness_loro_free(HarnessLoro *);
void harness_loro_buffer_free(HarnessLoroBuffer);
enum HarnessLoroOp {
    HARNESS_LORO_RECONCILE_PROJECTION = 1,
    HARNESS_LORO_PROJECTION = 2,
    HARNESS_LORO_WIRE_SNAPSHOT = 3,
    HARNESS_LORO_IMPORT = 4,
    HARNESS_LORO_BINARY_VERSION_VECTOR = 5,
    HARNESS_LORO_CONTAINS_VERSION_VECTOR = 6,
    HARNESS_LORO_PRIVATE_PERSISTENCE = 7,
    HARNESS_LORO_RESTORE_PRIVATE = 8,
    HARNESS_LORO_UNQUEUED_UPDATE = 9,
    HARNESS_LORO_UPDATE_DURABLY_QUEUED = 10,
    HARNESS_LORO_HAS_PENDING_IMPORTS = 11,
    HARNESS_LORO_EXPORT_SINCE_VERSION_VECTOR = 12,
    HARNESS_LORO_BASELINE_PROJECTION = 13,
    HARNESS_LORO_EVALUATE_COMMANDS = 14
};
#endif
