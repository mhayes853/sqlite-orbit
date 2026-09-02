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

/// A ``DatabaseDriver`` that runs reads concurrently against a pool of connections while
/// serializing writes through one.
///
/// The database runs in WAL mode, which is what lets readers keep working while a write is in
/// flight. Writes queue on an actor, so a hundred tasks writing at once suspend in turn rather than
/// occupying a hundred threads.
public final class SQLitePoolDriver: DatabaseDriver, Sendable {
  public typealias ReadTransaction = SQLiteReadTransaction
  public typealias WriteTransaction = SQLiteWriteTransaction

  public let defaultIdentifier: DatabaseIdentifier

  private let writer: SQLiteConnectionActor
  private let readers: SQLiteReaderPool
  private let synchronousReader: SQLiteConnectionStorage

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
    let resolvedIdentifier = identifier ?? .forDatabase(path: path)

    // Moving a new database into WAL briefly needs an exclusive lock of SQLite's own, so processes
    // opening it at the same moment would otherwise contend for it.
    let connections = try Self.withOpenLock(
      identifier: resolvedIdentifier,
      directory: coordinationDirectory
    ) {
      try Self.openConnections(path: path, configuration: configuration)
    }

    self.defaultIdentifier = resolvedIdentifier
    self.writer = SQLiteConnectionActor(storage: connections.writer)
    self.synchronousReader = connections.synchronousReader
    self.readers = SQLiteReaderPool(
      readers: connections.readers.map(SQLiteConnectionActor.init(storage:))
    )
  }

  private static func openConnections(
    path: String,
    configuration: SQLiteConfiguration
  ) throws -> (
    writer: SQLiteConnectionStorage,
    readers: [SQLiteConnectionStorage],
    synchronousReader: SQLiteConnectionStorage
  ) {
    var writerConfiguration = configuration
    writerConfiguration.setupSQL.append("PRAGMA journal_mode = WAL")
    let writer = try SQLiteConnectionStorage(
      path: path,
      flags: [.readWrite, .create, .noMutex],
      configuration: writerConfiguration
    )

    // `query_only` is belt and braces over the read-only flag: it turns a write attempted through
    // the raw connection into an error rather than a surprise.
    var readerConfiguration = configuration
    readerConfiguration.setupSQL.append("PRAGMA query_only = ON")
    func openReader() throws -> SQLiteConnectionStorage {
      try SQLiteConnectionStorage(
        path: path,
        flags: [.readOnly, .noMutex],
        configuration: readerConfiguration
      )
    }

    let readers = try (0..<max(1, configuration.readerCount)).map { _ in try openReader() }
    // Synchronous reads cannot enter an actor, so they get a connection of their own rather than
    // blocking either the pool or, worse, the single writer.
    return (writer, readers, try openReader())
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

  nonisolated(nonsending)
  public func read<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteReadTransaction) throws -> sending Result
  ) async throws -> sending Result {
    let reader = try await readers.acquire()
    let result: Result
    do {
      result = try await withInterruptOnCancellation(reader.storage) {
        try await reader.read(body)
      }
    } catch {
      // Returning the reader is awaited rather than deferred to a task: a reader that comes back
      // late is a reader the next caller waits for while it is already free.
      await readers.release(reader)
      throw error
    }
    await readers.release(reader)
    return result
  }

  nonisolated(nonsending)
  public func write<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteWriteTransaction) throws -> sending Result
  ) async throws -> sending Result {
    try await withInterruptOnCancellation(writer.storage) {
      try await writer.write(body)
    }
  }

  /// Reads without an asynchronous context, blocking the calling thread.
  ///
  /// This uses a connection reserved for it, so it neither takes a reader out of the pool nor waits
  /// on the writer. Prefer ``read(_:)``, which suspends instead of blocking.
  ///
  /// There is deliberately no synchronous counterpart for writing: a database has one writer, and
  /// blocking a thread on it is the easiest way to stall every other writer behind it.
  public func readSynchronously<Result: Sendable>(
    _ body: @Sendable (borrowing SQLiteReadTransaction) throws -> sending Result
  ) throws -> sending Result {
    try synchronousReader.connection.withLock { connection in
      try runRead(on: connection, body)
    }
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
