#if Vectors
  import CSQLiteOrbitVec

  private let sqliteVecInitializer: SQLiteExtensionInitializer = sqlite_orbit_vec_init

  extension SQLiteConfiguration {
    /// Enables SQLite Vec for this configuration's selected library.
    ///
    /// Call this explicitly after choosing `library` and before opening any connections. The
    /// `Vectors` trait provides the integration but does not register it automatically.
    ///
    /// Apple system SQLite initializes the SDK-compiled extension on each connection through a
    /// prepended setup. If you replace `setups`, call this again to restore that setup.
    /// Other runtimes register an automatic initializer immediately. Registration affects all
    /// future connections in that runtime, including connections outside Orbit; existing
    /// connections are unaffected. Repeated automatic registration is a harmless no-op.
    ///
    /// A custom runtime must provide `SQLiteLibrary.extensions` with automatic registration
    /// support. On Apple platforms, Vec calls the linked `sqlite3_*` symbols directly, so the
    /// custom runtime must be the sole provider of those symbols, as with SQLCipher.
    ///
    /// - Throws: `SQLiteFeatureUnavailableError` for unsupported runtimes, or `SQLiteError` when
    ///   automatic registration fails. Apple per-connection initialization errors fail the open.
    public mutating func registerSQLiteVec() throws {
      if library.extensions?.isAppleSystemSQLite == true {
        setups.insert(
          SQLiteSetup { connection in
            guard connection.sqlite.extensions?.isAppleSystemSQLite == true else { return }
            let code = sqliteVecInitializer(connection.sqliteConnection, nil, nil)
            guard code == SQLiteResultCode.ok.rawValue else {
              throw SQLiteError.reported(
                by: connection.sqlite,
                on: connection.sqliteConnection,
                code: code,
                sql: nil
              )
            }
          },
          at: 0
        )
      } else {
        guard library.extensions?.autoExtensions != nil else {
          throw SQLiteFeatureUnavailableError(libraryName: library.name, feature: .sqliteVec)
        }
        try library.registerAutoExtension(sqliteVecInitializer)
      }
    }
  }
#endif
