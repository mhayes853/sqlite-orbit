#if Vectors
  import CSQLiteOrbitVec

  private let sqliteVecInitializer: SQLiteExtensionInitializer = sqlite_orbit_vec_init

  extension SQLiteConfiguration {
    /// Arranges SQLite Vec initialization before user setup runs on every connection.
    ///
    /// Configurations already register this when the `Vectors` package trait is enabled.
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
            if library.extensions?.isAppleSystemSQLite == true { return }
            guard library.extensions?.autoExtensions != nil else {
              throw SQLiteFeatureUnavailableError(libraryName: library.name, feature: .sqliteVec)
            }
            try library.registerAutoExtension(sqliteVecInitializer)
          },
          install: { connection in
            guard connection.sqlite.extensions?.isAppleSystemSQLite == true else {
              // Automatic extensions were initialized by SQLite during `open`.
              return SQLiteResultCode.ok.rawValue
            }
            return sqliteVecInitializer(connection.sqliteConnection, nil, nil)
          }
        ),
        at: 0
      )
    }
  }
#endif
