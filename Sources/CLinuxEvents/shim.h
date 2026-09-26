#ifndef SQLITE_ORBIT_CLINUXEVENTS_SHIM_H
#define SQLITE_ORBIT_CLINUXEVENTS_SHIM_H

// Swift's Glibc module leaves out the headers the IPC transport's thread waits with, so they are
// imported through this module instead, along with the one its directory watches use.
#if defined(__linux__)
#include <stdint.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/inotify.h>

// Glibc declares these as enumerators, Musl as plain macros, and Bionic as macros that cast to a
// kernel type, so each C library would import them as a different Swift type, or not at all. The
// constants here carry the same values as one type everywhere.
static const uint32_t orbit_epoll_in = EPOLLIN;
static const uint32_t orbit_epoll_out = EPOLLOUT;
static const int orbit_epoll_ctl_add = EPOLL_CTL_ADD;
static const int orbit_epoll_ctl_del = EPOLL_CTL_DEL;
static const int orbit_epoll_cloexec = EPOLL_CLOEXEC;
static const int orbit_efd_cloexec = EFD_CLOEXEC;
static const int orbit_efd_nonblock = EFD_NONBLOCK;
static const int orbit_in_cloexec = IN_CLOEXEC;
static const int orbit_in_nonblock = IN_NONBLOCK;

// What changes a watched directory's entries, or the directory itself.
static const uint32_t orbit_in_entries_changed =
    IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF;
#endif

#endif
