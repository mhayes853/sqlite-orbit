#if StructuredQueries
  // Re-exported so that `import SQLiteOrbit` brings the query builder with it when the
  // `StructuredQueries` trait is on. Code that builds statements uses these APIs constantly, and
  // they are part of this package's public API under the trait. This is the one exception to
  // traits only adding declarations: turning the trait on also brings the query builder's names
  // into scope.
  @_exported import StructuredQueriesSQLite
#endif
