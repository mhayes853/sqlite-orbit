#if Vectors
  import CSQLiteOrbitVec

  private let sqliteVecInitializer: SQLiteExtensionInitializer = sqlite_orbit_vec_init

  extension SQLiteConfiguration {
    /// Arranges SQLite Vec initialization before user setup runs on every connection.
    ///
    /// Configurations initialize Vec automatically when the `Vectors` package trait is enabled
    /// and the selected library supports extension registration.
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
      addSQLiteVecSetup(isRequired: true)
    }

    mutating func registerSQLiteVecIfAvailable() {
      addSQLiteVecSetup(isRequired: false)
    }

    private mutating func addSQLiteVecSetup(isRequired: Bool) {
      connectionSetups.insert(
        SQLiteConnectionSetup(
          prepare: { library in
            if library.extensions?.isAppleSystemSQLite == true { return }
            guard library.extensions?.autoExtensions != nil else {
              if !isRequired { return }
              throw SQLiteFeatureUnavailableError(libraryName: library.name, feature: .sqliteVec)
            }
            try library.registerAutoExtension(sqliteVecInitializer)
          },
          install: { connection in
            guard connection.sqlite.extensions?.isAppleSystemSQLite == true else {
              // Automatic extensions initialize during open; unsupported libraries skip
              // optional setup or fail an explicit request during preparation.
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
