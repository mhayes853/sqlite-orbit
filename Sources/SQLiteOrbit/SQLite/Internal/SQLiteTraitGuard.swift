// SQLCipher is a fork of SQLite and exports the same `sqlite3_*` names, so enabling both traits
// links two builds under one set of symbols and leaves the link order to decide which one every
// call reaches. Traits are additive and SwiftPM will not refuse the combination on its own.
#if SystemSQLite && SQLCipher
  #error(
    """
    The SystemSQLite and SQLCipher traits cannot both be enabled: they export the same sqlite3_* \
    symbols, so the link order would decide which build every call reaches. Depend on this package \
    with `traits: ["SQLCipher"]`, which leaves the default traits out.
    """
  )
#endif
