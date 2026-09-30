#if StructuredQueries
  // Re-exported so that `import SQLiteOrbit` brings the query builder with it when the
  // `StructuredQueries` trait is on. Code that builds statements uses these APIs constantly, and
  // they are part of this package's public API under the trait. This is the one exception to
  // traits only adding declarations: turning the trait on also brings the query builder's names
  // into scope.
  @_exported import StructuredQueriesSQLite
#endif

#if SQLiteVec
  @_exported import StructuredQueriesSQLiteVecCore
  #if SystemSQLite
    // CSQLiteVec includes the platform SQLite headers. Custom builds such as SQLCipher may
    // define different versions of those structs, so their Swift code uses the opaque C bridge.
    @_exported import CSQLiteVec
  #endif
#endif
