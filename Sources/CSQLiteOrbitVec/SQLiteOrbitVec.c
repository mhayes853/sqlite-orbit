#include "CSQLiteOrbitVec.h"

// SwiftPM also compiles unreferenced local targets when building the whole package.
#ifdef SQLITE_ORBIT_VEC
#include <sqlite3ext.h>

// Keep API-table inspection out of Swift's Clang importer: its SQLite headers may differ from
// those used by SQLCipher or another custom build, causing conflicting struct definitions.

// Vec's extension entry point has SQLite's standard initializer ABI.
extern int sqlite3_vec_init(sqlite3 *, char **, const sqlite3_api_routines *);

int sqlite_orbit_vec_init(sqlite3 *connection, char **error, const void *api) {
  const sqlite3_api_routines *routines = api;
#ifndef __APPLE__
  // Builds omitting extension loading or virtual tables must fail rather than call null pointers.
  if (!routines || !routines->create_function_v2 || !routines->create_module_v2) {
    return SQLITE_ERROR;
  }
#endif
  return sqlite3_vec_init(connection, error, routines);
}
#endif
