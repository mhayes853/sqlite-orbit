#if SystemSQLite && (canImport(Darwin) || canImport(Glibc))
  import Foundation

  extension CrossProcessDatabase where Driver == SQLitePoolDriver {
    /// Opens the SQLite database at `path` for access from any process using the same coordination
    /// directory.
    ///
    /// The database is opened by ``SQLitePoolDriver``, so it runs in WAL mode with concurrent
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
    public convenience init(
      path: String,
      configuration: SQLiteConfiguration = .default,
      id: DatabaseIdentifier? = nil,
      coordination: UnixDatagramDatabaseIPCTransport.Configuration = .default,
      onAnnouncementFailure: (@Sendable (any Error) -> Void)? = nil
    ) throws {
      let identifier = id ?? .forDatabase(path: path)
      self.init(
        driver: try SQLitePoolDriver(
          path: path,
          configuration: configuration,
          identifier: identifier,
          coordinationDirectory: coordination.directory
        ),
        id: identifier,
        transport: try UnixDatagramDatabaseIPCTransport.shared(configuration: coordination),
        onAnnouncementFailure: onAnnouncementFailure
      )
    }
  }

  /// A cross-process database backed by the package's own SQLite driver.
  ///
  /// This is the default: it needs no third-party dependency, and it is the one that can be pointed
  /// at a SQLite build of your choosing.
  ///
  /// Prefer this spelling to `CrossProcessDatabase(path:)`. Both drivers offer an `init(path:)`, so
  /// with the `GRDB` trait also enabled there is nothing for the compiler to infer the driver from;
  /// naming the database type says which one you meant.
  public typealias SQLiteCrossDatabase = CrossProcessDatabase<SQLitePoolDriver>
#endif
