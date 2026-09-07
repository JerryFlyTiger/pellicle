// CPlatform: C shims for functions with no Swift declaration in any SDK module.
//
// `sys_icache_invalidate` (libkern/OSCacheControl.h) has no Swift declaration in any
// SDK module, and binding to it with `@_silgen_name` (as the 2026-09-05 spike did) has
// no type checking and would break silently if the symbol's signature changed. Wrapping
// it in a tiny, typed C shim gives the Swift side a real declaration to check against.
#ifndef CPLATFORM_H
#define CPLATFORM_H

#include <stddef.h>

void pellicle_icache_invalidate(void *start, size_t len);

#endif
