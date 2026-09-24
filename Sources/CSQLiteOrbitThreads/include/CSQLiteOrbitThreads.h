#ifndef SQLITE_ORBIT_CSQLITEORBITTHREADS_H
#define SQLITE_ORBIT_CSQLITEORBITTHREADS_H

// The pthread connection executor's reach into C. Windows has no pthreads, so there is nothing
// here for it, and Darwin builds this without using it.
#if !defined(_WIN32)

#include <pthread.h>
#include <time.h>

// Names the calling thread, or returns an error where a thread cannot be named.
int csqliteorbit_set_current_thread_name(const char *name);

// Reads the monotonic clock that `csqliteorbit_condattr_set_monotonic_clock` sets a condition to.
int csqliteorbit_monotonic_now(struct timespec *now);

// Makes a condition's timed waits measure against the monotonic clock.
int csqliteorbit_condattr_set_monotonic_clock(pthread_condattr_t *attributes);

#endif

#endif
