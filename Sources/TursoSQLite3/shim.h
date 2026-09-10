#ifndef SQLITE_ORBIT_TURSO_SQLITE3_SHIM_H
#define SQLITE_ORBIT_TURSO_SQLITE3_SHIM_H

// Turso's C compatibility layer implements SQLite's public ABI. Using the platform header here
// keeps this source target tiny; a distributed artifact bundle should package Turso's generated
// bindings/c/include/sqlite3.h under the same module name.
#include <sqlite3.h>

#endif
