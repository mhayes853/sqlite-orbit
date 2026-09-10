// Each built-in library exports the same `sqlite3_*` names, so enabling more than one links
// multiple builds under one set of symbols and leaves the link order to decide which one every
// call reaches. Traits are additive and SwiftPM will not refuse the combination on its own.
#if (SystemSQLite && SQLCipher) || (SystemSQLite && Turso) || (SQLCipher && Turso)
  #error(
    """
    The SystemSQLite, SQLCipher, and Turso traits are mutually exclusive: they export the same \
    sqlite3_* symbols, so the link order would decide which build every call reaches. Depend on \
    this package with only the trait for the library you want, which leaves the defaults out.
    """
  )
#endif
