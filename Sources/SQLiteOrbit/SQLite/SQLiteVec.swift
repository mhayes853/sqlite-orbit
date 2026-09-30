#if SQLiteVec
  import CSQLiteVec

  // This is the function pointer SQLite retains. It also guards a runtime compiled with
  // SQLITE_OMIT_LOAD_EXTENSION: on non-Apple builds Vec needs an API table, and returning an error
  // makes opening the connection fail rather than dereferencing a null table.
  private let sqliteVecInitializer: SQLiteExtensionInitializer = { connection, error, api in
    let routines = api?.assumingMemoryBound(to: sqlite3_api_routines.self)
    #if !canImport(Darwin)
      guard
        let routines,
        routines.pointee.create_function_v2 != nil,
        routines.pointee.create_module_v2 != nil
      else { return SQLiteResultCode.error.rawValue }
    #endif
    return sqlite3_vec_init(connection, error, routines)
  }

  extension SQLiteConfiguration {
    /// Arranges SQLite Vec initialization before user setup runs on every connection.
    ///
    /// Configurations already register this when the `SQLiteVec` package trait is enabled.
    /// Call it again only if you replaced ``connectionSetups`` and want to restore Vec setup.
    ///
    /// Apple system SQLite initializes the SDK-compiled extension directly on each connection.
    /// Other runtimes register an automatic initializer before opening connections. Registration
    /// affects all future connections in that runtime, including connections outside Orbit.
    ///
    /// A custom runtime must provide ``SQLiteLibrary/extensions`` with automatic registration
    /// support. On Apple platforms, Vec calls the linked `sqlite3_*` symbols directly, so the
    /// custom runtime must be the sole provider of those symbols, as with SQLCipher.
    /// Unsupported runtimes and registration failures fail the connection's open.
    public mutating func registerSQLiteVec() {
      connectionSetups.insert(
        SQLiteConnectionSetup(
          prepare: { library in
            guard let extensions = library.extensions else {
              throw SQLiteFeatureUnavailableError(libraryName: library.name, feature: .sqliteVec)
            }
            #if canImport(Darwin)
              if extensions.isAppleSystemSQLite { return }
            #endif
            guard extensions.autoExtensions != nil else {
              throw SQLiteFeatureUnavailableError(libraryName: library.name, feature: .sqliteVec)
            }
            try library.registerAutoExtension(sqliteVecInitializer)
          },
          install: { connection in
            #if canImport(Darwin)
              if connection.sqlite.extensions?.isAppleSystemSQLite == true {
                return sqliteVecInitializer(connection.sqliteConnection, nil, nil)
              }
            #endif
            // Automatic extensions were initialized by SQLite during `open`.
            return SQLiteResultCode.ok.rawValue
          }
        ),
        at: 0
      )
    }
  }
#endif
