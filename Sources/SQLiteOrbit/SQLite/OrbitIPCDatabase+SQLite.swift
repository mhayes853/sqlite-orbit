#if BuiltInSQLite && (canImport(Darwin) || os(Linux) || os(Android))

  extension OrbitIPCDatabase {
    /// Opens the SQLite database at `path` for access from any process using the same coordination
    /// directory.
    ///
    /// The database is opened by ``SQLitePool``, so it runs in WAL mode with concurrent
    /// readers and a single writer, and every connection waits by a busy policy — without one, a
    /// write that overlaps another process's write fails outright rather than waiting its turn.
    ///
    /// - Parameters:
    ///   - path: The path of the SQLite database file. In-memory databases cannot be shared between
    ///     processes, or pooled.
    ///   - configuration: The settings applied to every connection. Supply a different
    ///     ``SQLiteConfiguration/library`` to run against your own SQLite build.
    ///   - identifier: The identity shared by every process that opens this database. Defaults to
    ///     the database's standardized path.
    ///   - coordination: Describes the directory and buffer sizes this process uses to reach its
    ///     peers. Processes coordinate only when they share a coordination directory, which also
    ///     holds the advisory lock that serializes opening the database: another process opening
    ///     it holds this one up for as long as `configuration`'s busy policy lets SQLite wait for a
    ///     lock, and no longer, so one frozen partway through its open cannot hold it up for good.
    ///   - delegate: Receives important events that cannot be surfaced through an operation. The
    ///     database holds it weakly.
    ///
    /// ```swift
    /// let database = try OrbitIPCDatabase(path: OrbitDatabasePath("reminders.sqlite"))
    /// try await database.write { transaction in
    ///   try transaction.execute("CREATE TABLE IF NOT EXISTS reminders (...)")
    /// }
    /// ```
    ///
    /// - Throws: A ``SQLiteError`` if the database cannot be opened, including one with
    ///   `SQLITE_BUSY` when another process has held the open lock for longer than the busy policy
    ///   waits, or a ``UnixDatagramIPCTransport/SystemError`` if this process cannot join the
    ///   coordination directory.
    public convenience init(
      path: OrbitDatabasePath,
      configuration: SQLiteConfiguration = .default,
      identifier: OrbitDatabaseIdentifier? = nil,
      coordination: UnixDatagramIPCTransport.Configuration = .default,
      delegate: (any OrbitIPCDatabase.Delegate)? = nil
    ) throws {
      guard case .multipleProcesses = configuration.library.fileSharing else {
        throw SQLiteFeatureUnavailableError(
          libraryName: configuration.library.name,
          feature: .multiprocessFileSharing
        )
      }
      let identifier = identifier ?? .forDatabase(path: path)
      // Moving a new database into WAL briefly needs an exclusive lock of SQLite's own, so
      // processes opening it at the same moment would otherwise contend for it.
      let writer = try OrbitDatabaseOpenLock.withLock(
        databaseIdentifier: identifier,
        directory: OrbitCoordinationDirectory(path: coordination.directoryPath),
        configuration: configuration
      ) {
        try SQLitePool(path: path, configuration: configuration)
      }
      self.init(
        writer: writer,
        identifier: identifier,
        transport: try UnixDatagramIPCTransport.shared(configuration: coordination),
        delegate: delegate
      )
    }
  }
#endif
