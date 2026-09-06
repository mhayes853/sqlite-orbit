#if BuiltInSQLite && (canImport(Darwin) || canImport(Glibc))

  extension OrbitDatabase where Writer == SQLitePool {
    /// Opens the SQLite database at `path` for access from any process using the same coordination
    /// directory.
    ///
    /// The database is opened by ``SQLitePool``, so it runs in WAL mode with concurrent
    /// readers and a single writer, and every connection gets a busy timeout — without one, a write
    /// that overlaps another process's write fails outright rather than waiting its turn.
    ///
    /// - Parameters:
    ///   - path: The path of the SQLite database file. In-memory databases cannot be shared between
    ///     processes, or pooled.
    ///   - configuration: The settings applied to every connection. Supply a different
    ///     ``SQLiteConfiguration/library`` to run against your own SQLite build.
    ///   - id: The identity shared by every process that opens this database. Defaults to the
    ///     database's standardized path.
    ///   - coordination: Describes the directory and back pressure this process uses to reach its
    ///     peers. Processes coordinate only when they share a coordination directory.
    ///   - onAnnouncementFailure: Receives the error when announcing a committed write fails.
    ///
    /// ```swift
    /// @Table struct Reminder { let id: Int; var title: String; var isCompleted = false }
    ///
    /// let database = try OrbitDatabase(path: OrbitDatabasePath("reminders.sqlite"))
    /// try await database.write { transaction in
    ///   try #sql("CREATE TABLE IF NOT EXISTS reminders (...)", as: Void.self).execute(transaction)
    /// }
    /// ```
    ///
    /// - Throws: A ``SQLiteError`` if the database cannot be opened, or a transport error if this
    ///   process cannot join the coordination directory.
    public convenience init(
      path: OrbitDatabasePath,
      configuration: SQLiteConfiguration = .default,
      id: OrbitDatabaseIdentifier? = nil,
      coordination: UnixDatagramIPCTransport.Configuration = .default,
      onAnnouncementFailure: (@Sendable (any Error) -> Void)? = nil
    ) throws {
      let identifier = id ?? .forDatabase(path: path)
      self.init(
        writer: try SQLitePool(
          path: path,
          configuration: configuration,
          identifier: identifier,
          coordinationDirectory: coordination.directory
        ),
        id: identifier,
        transport: try UnixDatagramIPCTransport.shared(configuration: coordination),
        onAnnouncementFailure: onAnnouncementFailure
      )
    }
  }
#endif
