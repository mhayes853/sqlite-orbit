#ifndef CSQLITE_ORBIT_VEC_H
#define CSQLITE_ORBIT_VEC_H

struct sqlite3;

// The API table stays opaque so importing this header never imports a second SQLite build.
int sqlite_orbit_vec_init(struct sqlite3 *connection, char **error, const void *api);

#endif
