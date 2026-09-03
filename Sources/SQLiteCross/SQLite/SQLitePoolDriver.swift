import Foundation

/// Reported when a database cannot be pooled.
public struct SQLitePoolUnavailableError: Error, CustomStringConvertible {
  public let path: String

  public var description: String {
    """
    An in-memory database is private to the connection that opened it, so a pool's readers would \
    each see a different, empty database. Use SQLiteQueueDriver for "\(path)".
    """
  }
}

/// A ``SQLiteDatabaseWriter`` that runs reads concurrently against a pool of connections while
/// serializing writes through one.
///
/// Reads run alongside one another. A write waits for the reads in flight and holds off the reads
/// queued behind it, so a read issued after a write observes it. The database runs in WAL mode so
/// that other processes' readers are never blocked by this one's writer.
public final class SQLitePoolDriver: SQLiteDatabaseWriter, Sendable {
  public let defaultIdentifier: DatabaseIdentifier

  private let writer: SQLiteConnection
  private let scheduler: SQLitePoolScheduler

  /// Opens `path` as a WAL database with one writer and `configuration.readerCount` readers.
  ///
  /// - Parameters:
  ///   - path: The database file. In-memory databases cannot be pooled.
  ///   - configuration: The settings applied to every connection.
  ///   - identifier: The identity shared with other processes. Defaults to the standardized path.
  ///   - coordinationDirectory: Where the advisory lock that serializes opening lives. Processes
  ///     coordinate only when they share it.
  public init(
    path: String,
    configuration: SQLiteConfiguration,
    identifier: DatabaseIdentifier? = nil,
    coordinationDirectory: URL? = nil
  ) throws {
    guard !path.isEmpty, path != ":memory:", !path.hasPrefix("file::memory:") else {
      throw SQLitePoolUnavailableError(path: path)
    }
    let identifier = identifier ?? .forDatabase(path: path)

    // Moving a new database into WAL briefly needs an exclusive lock of SQLite's own, so processes
    // opening it at the same moment would otherwise contend for it.
    let (writer, readers) = try Self.withOpenLock(
      identifier: identifier,
      directory: coordinationDirectory
    ) {
      try Self.openConnections(path: path, configuration: configuration)
    }

    self.defaultIdentifier = identifier
    self.writer = writer
    self.scheduler = SQLitePoolScheduler(readers: readers)
  }

  private static func openConnections(
    path: String,
    configuration: SQLiteConfiguration
  ) throws -> (writer: SQLiteConnection, readers: [SQLiteConnection]) {
    var writerConfiguration = configuration
    writerConfiguration.setupSQL.append("PRAGMA journal_mode = WAL")
    let writer = try SQLiteConnection(
      path: path,
      flags: [.readWrite, .create, .noMutex],
      configuration: writerConfiguration
    )

    // `query_only` is belt and braces over the read-only flag: it turns a write attempted through
    // the raw connection into an error rather than a surprise.
    var readerConfiguration = configuration
    readerConfiguration.setupSQL.append("PRAGMA query_only = ON")
    let readers = try (0..<max(1, configuration.readerCount)).map { _ in
      try SQLiteConnection(
        path: path,
        flags: [.readOnly, .noMutex],
        configuration: readerConfiguration
      )
    }
    return (writer, readers)
  }

  private static func withOpenLock<Result>(
    identifier: DatabaseIdentifier,
    directory: URL?,
    _ body: () throws -> Result
  ) throws -> Result {
    #if canImport(Darwin) || canImport(Glibc)
      return try DatabaseOpenLock.withLock(
        databaseIdentifier: identifier,
        directory: directory ?? UnixDatagramDatabaseIPCTransport.Configuration.defaultDirectory,
        body
      )
    #else
      return try body()
    #endif
  }

  public func read<Result: Sendable>(
    _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
  ) async throws -> Result {
    let reader = try await scheduler.acquireReader()
    // Giving the reader back is awaited rather than deferred to a task: a reader that comes back
    // late is a reader the next caller waits for while it is already free.
    let value: Result
    do {
      value = try await reader.read(body)
    } catch {
      await scheduler.releaseReader(reader)
      throw error
    }
    await scheduler.releaseReader(reader)
    return value
  }

  public func write<Result: Sendable>(
    _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
  ) async throws -> Result {
    try await scheduler.acquireWriter()
    let value: Result
    do {
      value = try await writer.write(body)
    } catch {
      await scheduler.releaseWriter()
      throw error
    }
    await scheduler.releaseWriter()
    return value
  }
}

#if SystemSQLite
  extension SQLitePoolDriver {
    /// Opens a pooled database using the SQLite this package was linked against.
    public convenience init(
      path: String,
      identifier: DatabaseIdentifier? = nil,
      coordinationDirectory: URL? = nil
    ) throws {
      try self.init(
        path: path,
        configuration: .default,
        identifier: identifier,
        coordinationDirectory: coordinationDirectory
      )
    }
  }
#endif
