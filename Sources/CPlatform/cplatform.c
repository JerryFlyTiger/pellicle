#include "include/cplatform.h"

#include <libkern/OSCacheControl.h>

void swiftemacs_icache_invalidate(void *start, size_t len) {
    sys_icache_invalidate(start, len);
}
