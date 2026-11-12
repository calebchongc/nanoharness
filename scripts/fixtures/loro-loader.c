/* Synthetic loader rejection fixtures; never a document implementation. */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#ifndef ABI
#define ABI 1
#endif
#ifndef CAPS
#define CAPS 0x3f
#endif
uint32_t harness_loro_abi_version(void) { return ABI; }
uint64_t harness_loro_capabilities(void) { return CAPS; }
typedef struct { unsigned char *ptr; size_t len; } Buffer;
/* A rejection must happen before any document call; abort makes violations
 * observable instead of letting an invalid implementation appear usable. */
int harness_loro_new(const unsigned char *p, size_t n, void **h, Buffer *b) { abort(); }
#ifndef OMIT_CALL
int harness_loro_call(void *h, uint32_t op, const unsigned char *p, size_t n, Buffer *b) { abort(); }
#endif
void harness_loro_free(void *h) { abort(); }
void harness_loro_buffer_free(Buffer b) { abort(); }
