// Glibc and Musl declare `pthread_setname_np` only under this, and Swift reads their headers
// without it, which is most of why this target exists.
#define _GNU_SOURCE

#include "CSQLiteOrbitThreads.h"

#if !defined(_WIN32)

#include <errno.h>

int csqliteorbit_set_current_thread_name(const char *name) {
#if defined(__linux__)
  return pthread_setname_np(pthread_self(), name);
#else
  (void)name;
  return ENOSYS;
#endif
}

// Clock ids are the addresses of C globals on WASI, which Swift cannot import, so the clock is
// named here rather than in Swift.
int csqliteorbit_monotonic_now(struct timespec *now) {
  return clock_gettime(CLOCK_MONOTONIC, now);
}

int csqliteorbit_condattr_set_monotonic_clock(pthread_condattr_t *attributes) {
#if defined(__APPLE__)
  (void)attributes;
  return ENOSYS;
#else
  return pthread_condattr_setclock(attributes, CLOCK_MONOTONIC);
#endif
}

#endif
