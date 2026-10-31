#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  // Native names are available from the overlay import without re-exporting Orbit's SQL and Row.
  public typealias SQLiteQueue = SQLiteOrbit.SQLiteQueue
  public typealias SQLitePool = SQLiteOrbit.SQLitePool
  public typealias OrbitIPCDatabase = SQLiteOrbit.OrbitIPCDatabase
  public typealias OrbitDatabasePath = SQLiteOrbit.OrbitDatabasePath
  public typealias SQLiteConfiguration = SQLiteOrbit.SQLiteConfiguration
  public typealias SQLiteLibrary = SQLiteOrbit.SQLiteLibrary
  public typealias InMemoryIPCTransport = SQLiteOrbit.InMemoryIPCTransport
  public typealias OrbitIPCTransport = SQLiteOrbit.OrbitIPCTransport
  public typealias OrbitDatabaseIdentifier = SQLiteOrbit.OrbitDatabaseIdentifier

  #if Turso
    public typealias TursoPool = SQLiteOrbit.TursoPool
  #endif

  public protocol DatabaseReader: AnyObject, Sendable {
    var path: String { get }

    var configuration: Configuration { get }

    /// The native handle used for access, migrations, and observation. Wrappers preserve its identity.
    var orbitDatabase: any OrbitObservableDatabaseWriter { get }

    @_disfavoredOverload
    func read<T>(_ value: (Database) throws -> T) throws -> T

    func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T

    @_disfavoredOverload
    func unsafeRead<T>(_ value: (Database) throws -> T) throws -> T

    func unsafeRead<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T

    func asyncUnsafeRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void)
  }

  public protocol DatabaseWriter: DatabaseReader {
    @_disfavoredOverload
    func write<T>(_ updates: (Database) throws -> T) throws -> T

    func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T

    @_disfavoredOverload
    func writeWithoutTransaction<T>(_ updates: (Database) throws -> T) throws -> T

    func writeWithoutTransaction<T: Sendable>(_ updates: @Sendable (Database) throws -> T)
      async throws -> T

    func asyncWriteWithoutTransaction(_ updates: @escaping @Sendable (Database) -> Void)
  }

  // Synchronous GRDB access accepts non-Sendable results and closures. These boxes transfer ownership
  // across a single synchronous call: no caller can use the captured state until that call returns.
  private struct SynchronousTransfer<Value>: @unchecked Sendable {
    let value: Value
  }

  // A native access may fail during cleanup after its scoped callback has run. Delivery remains
  // exactly once, and the callback is released before invocation so it can schedule another access.
  final class DatabaseAccessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<Database, Error>) -> Void)?

    init(_ completion: @escaping @Sendable (Result<Database, Error>) -> Void) {
      self.completion = completion
    }

    func callAsFunction(_ result: Result<Database, Error>) {
      let callback = lock.withLock {
        let callback = completion
        completion = nil
        return callback
      }
      callback?(result)
    }
  }

  extension DatabaseReader {
    private var nativeMetadata: SQLiteDatabaseMetadata {
      guard let metadata = orbitDatabase.databaseMetadata else {
        preconditionFailure("the custom Orbit driver does not expose database metadata")
      }
      return metadata
    }

    public var path: String {
      nativeMetadata.path.sqlitePath
    }

    public var configuration: Configuration {
      let metadata = nativeMetadata
      return Configuration(native: metadata.configuration, readerCount: metadata.readerCount)
    }

    @_disfavoredOverload
    public func read<T>(_ value: (Database) throws -> T) throws -> T {
      try withoutActuallyEscaping(value) { value in
        let operation = SynchronousTransfer(value: value)
        return try translate {
          try orbitDatabase.readBlocking { transaction in
            try transaction.withScopedAccess {
              SynchronousTransfer(value: try enterAccess($0, isWriter: false, operation.value))
            }
          }
          .value
        }
      }
    }

    public func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
      try await translate {
        try await orbitDatabase.read { transaction in
          try transaction.withScopedAccess { try value(Database($0)) }
        }
      }
    }

    @_disfavoredOverload
    public func unsafeRead<T>(_ value: (Database) throws -> T) throws -> T {
      try withoutActuallyEscaping(value) { value in
        let operation = SynchronousTransfer(value: value)
        return try translate {
          try orbitDatabase.readWithoutTransactionBlocking { connection in
            try connection.withScopedAccess {
              SynchronousTransfer(value: try enterAccess($0, isWriter: false, operation.value))
            }
          }
          .value
        }
      }
    }

    public func unsafeRead<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T
    {
      try await translate {
        try await orbitDatabase.readWithoutTransaction { connection in
          try connection.withScopedAccess { try value(Database($0)) }
        }
      }
    }

    public func asyncRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
      let completion = DatabaseAccessCompletion(value)
      Task {
        do {
          try await read { completion(.success($0)) }
        } catch {
          completion(.failure(error))
        }
      }
    }

    /// Schedules read-only access without a transaction or a shared snapshot across queries.
    /// The database is valid only inside the callback. Acquisition failures are delivered as errors.
    public func asyncUnsafeRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
      let completion = DatabaseAccessCompletion(value)
      Task {
        do {
          try await unsafeRead { completion(.success($0)) }
        } catch {
          completion(.failure(error))
        }
      }
    }
  }

  extension DatabaseWriter {
    /// Schedules updates in a transaction. Completion runs after commit or rollback, before
    /// releasing the writer connection. Neither database argument may escape its closure.
    public func asyncWrite<T>(
      _ updates: @escaping @Sendable (Database) throws -> T,
      completion: @escaping @Sendable (Database, Result<T, Error>) -> Void
    ) {
      asyncWriteWithoutTransaction { db in
        do {
          var result: T?
          try db.inTransaction {
            result = try updates(db)
            return .commit
          }
          completion(db, .success(result!))
        } catch {
          completion(db, .failure(error))
        }
      }
    }

    /// Schedules access without opening a transaction. Handle SQL errors inside the closure.
    /// As with GRDB, this callback has no channel for connection acquisition failures.
    public func asyncWriteWithoutTransaction(_ updates: @escaping @Sendable (Database) -> Void) {
      Task {
        do {
          try await writeWithoutTransaction { updates($0) }
        } catch {
          preconditionFailure("could not acquire the database writer: \(error)")
        }
      }
    }

    // Writes run in a transaction managed by the overlay, as GRDB's `inTransaction`, so that
    // transaction statements are traced and `afterNextTransaction` callbacks run.
    @_disfavoredOverload
    public func write<T>(_ updates: (Database) throws -> T) throws -> T {
      try writeWithoutTransaction { db in
        var result: T?
        try db.inTransaction {
          result = try updates(db)
          return .commit
        }
        return result!
      }
    }

    public func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
      try await writeWithoutTransaction { db in
        var result: T?
        try db.inTransaction {
          result = try updates(db)
          return .commit
        }
        return result!
      }
    }

    @_disfavoredOverload
    public func writeWithoutTransaction<T>(_ updates: (Database) throws -> T) throws -> T {
      try withoutActuallyEscaping(updates) { updates in
        let operation = SynchronousTransfer(value: updates)
        return try translate {
          try orbitDatabase.writeWithoutTransactionBlocking { connection in
            try connection.withScopedAccess {
              SynchronousTransfer(value: try enterAccess($0, isWriter: true, operation.value))
            }
          }
          .value
        }
      }
    }

    public func writeWithoutTransaction<T: Sendable>(_ updates: @Sendable (Database) throws -> T)
      async throws -> T
    {
      try await translate {
        try await orbitDatabase.writeWithoutTransaction { connection in
          try connection.withScopedAccess { try updates(Database($0)) }
        }
      }
    }

    /// Runs `updates` outside a transaction, while no read runs. SQLiteOrbit's writes are
    /// already barriers against the reads of their pool, so this is `writeWithoutTransaction`.
    @_disfavoredOverload
    public func barrierWriteWithoutTransaction<T>(_ updates: (Database) throws -> T) throws -> T {
      try writeWithoutTransaction(updates)
    }

    /// Runs `updates` outside a transaction, while no read runs.
    public func barrierWriteWithoutTransaction<T: Sendable>(
      _ updates: @Sendable (Database) throws -> T
    ) async throws -> T {
      try await writeWithoutTransaction(updates)
    }

    public func erase() throws {
      try write { db in
        let tables = try String.fetchAll(
          db,
          sql: "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
        for table in tables {
          try db.execute(sql: "DROP TABLE \(quoted(table))")
        }
      }
    }
  }

  extension SQLiteOrbit.SQLiteQueue: DatabaseWriter {
    public var orbitDatabase: any OrbitObservableDatabaseWriter {
      self
    }
  }

  extension SQLiteOrbit.SQLitePool: DatabaseWriter {
    public var orbitDatabase: any OrbitObservableDatabaseWriter {
      self
    }
  }

  extension SQLiteOrbit.OrbitIPCDatabase: DatabaseWriter {
    public var orbitDatabase: any OrbitObservableDatabaseWriter {
      self
    }
  }

  #if Turso
    extension SQLiteOrbit.TursoPool: DatabaseWriter {
      public var orbitDatabase: any OrbitObservableDatabaseWriter {
        self
      }
    }
  #endif

  public struct Configuration: Sendable {
    private(set) var native: SQLiteConfiguration
    public var maximumReaderCount = 5

    /// The clock that provides `Database.transactionDate`.
    public var transactionClock: any TransactionClock = .default

    /// Whether statement arguments appear in error descriptions and trace events.
    public var publicStatementArguments = false

    /// Whether connections refuse writes. Opening a missing database file fails with
    /// `SQLITE_CANTOPEN`; writes fail with `SQLITE_READONLY` (through `PRAGMA query_only`).
    public var readonly = false

    /// A label for the database, used for diagnostics.
    public var label: String? = nil

    /// The journal mode of database queues.
    public var journalMode: JournalModeConfiguration = .default

    /// GRDB disables double-quoted string literals by default. SQLiteOrbit has no access to
    /// `sqlite3_db_config`, so this value is recorded but connections keep SQLite's default.
    public var acceptsDoubleQuotedStringLiterals = false

    /// Whether accesses may leave transactions open. SQLiteOrbit always refuses this.
    public var allowsUnsafeTransactions = false

    /// Recorded for source compatibility; SQLiteOrbit schedules accesses itself.
    public var qos: DispatchQoS = .default

    /// Recorded for source compatibility; SQLiteOrbit schedules accesses itself.
    public var targetQueue: DispatchQueue? = nil

    /// Recorded for source compatibility; SQLiteOrbit schedules accesses itself.
    public var writeTargetQueue: DispatchQueue? = nil

    /// Recorded for source compatibility; pool readers are always open.
    public var persistentReadOnlyConnections = false

    /// The busy mode of read-only pool connections, when it differs from `busyMode`.
    /// Recorded for source compatibility; all connections use `busyMode`.
    public var readonlyBusyMode: Database.BusyMode? = nil

    /// Recorded for source compatibility.
    public var observesSuspensionNotifications = false

    /// Recorded for source compatibility.
    public var automaticMemoryManagement = false

    /// Journal modes of database queues.
    public enum JournalModeConfiguration: Sendable {
      /// The default journal mode of SQLite.
      case `default`
      /// Write-ahead logging.
      case wal
    }

    /// The native configuration, with the GRDB-only options applied to each connection.
    var resolvedNative: SQLiteConfiguration {
      resolvedNative(registry: nil)
    }

    func resolvedNative(registry: ConnectionRegistry?) -> SQLiteConfiguration {
      var native = native
      if journalMode == .wal {
        native.journalMode = .wal
      }
      let configuration = self
      let publicStatementArguments = publicStatementArguments
      let readonly = readonly
      native.setups.append(
        SQLiteSetup { connection in
          try connection.withScopedAccess { access in
            let db = Database(access)
            registry?
              .register(try access.sqliteConnection, library: try access.configuration.library)
            db.connectionState.configuration = configuration
            db.connectionState.publicStatementArguments = publicStatementArguments
            if readonly {
              try db.execute(sql: "PRAGMA query_only = 1")
            }
          }
        }
      )
      return native
    }

    // GRDB opens read-only databases without creating them.
    func checkReadonlyPath(_ path: String) throws {
      let databasePath = OrbitDatabasePath(path)
      guard readonly, !databasePath.isPrivateToConnection,
        !FileManager.default.fileExists(atPath: databasePath.sqlitePath)
      else { return }
      throw DatabaseError(resultCode: .SQLITE_CANTOPEN)
    }

    public var foreignKeysEnabled: Bool {
      get {
        native.isForeignKeysEnabled
      }
      set {
        native.isForeignKeysEnabled = newValue
      }
    }

    public var library: SQLiteLibrary {
      get {
        native.library
      }
      set {
        native.library = newValue
      }
    }

    public var busyMode: Database.BusyMode {
      get {
        switch native.busyPolicy {
        case .handler(let callback): return .callback(callback)
        case .waitIndefinitely: return .timeout(Double(Int32.max) / 1000)
        case .timeout(let duration):
          if duration == .zero {
            return .immediateError
          }
          let parts = duration.components
          return .timeout(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
      }
      set {
        switch newValue {
        case .immediateError: native.busyPolicy = .timeout(.zero)
        case .timeout(let seconds): native.busyPolicy = .timeout(.seconds(seconds))
        case .callback(let callback): native.busyPolicy = .handler(callback)
        }
      }
    }

    public init(library: SQLiteLibrary) {
      native = SQLiteConfiguration(library: library, busyPolicy: .timeout(.zero))
      // Runs before every other setup, so a reused connection handle starts without state.
      native.setups.append(
        SQLiteSetup { connection in
          try connection.withScopedAccess {
            DatabaseConnectionState.reset(try $0.sqliteConnection)
            Database($0).installDefaultFunctionsAndCollations()
          }
        }
      )
    }

    #if BuiltInSQLite
      public init() {
        self.init(library: SQLiteConfiguration.default.library)
      }
    #endif

    public mutating func prepareDatabase(_ setup: @escaping @Sendable (Database) throws -> Void) {
      native.setups.append(
        SQLiteSetup { connection in
          try connection.withScopedAccess { try setup(Database($0)) }
        }
      )
    }

    init(native: SQLiteConfiguration, readerCount: Int) {
      self.native = native
      maximumReaderCount = readerCount
    }
  }

  extension Database {
    public enum BusyMode: Sendable {
      case immediateError
      case timeout(TimeInterval)
      case callback(Database.BusyCallback)
    }
  }

  public final class DatabaseQueue: DatabaseWriter, ConnectionRegistryOwner {
    public let orbitDatabase: any OrbitObservableDatabaseWriter
    let connectionRegistry = ConnectionRegistry()
    public let path: String
    public let configuration: Configuration

    public convenience init(configuration: Configuration) throws {
      try self.init(path: ":memory:", configuration: configuration)
    }

    public init(path: String, configuration: Configuration) throws {
      self.path = path
      self.configuration = configuration
      try configuration.checkReadonlyPath(path)
      let registry = connectionRegistry
      orbitDatabase = try translate {
        try SQLiteQueue(
          path: OrbitDatabasePath(path),
          configuration: configuration.resolvedNative(registry: registry)
        )
      }
    }

    /// Opens a private in-memory database. Unlike GRDB, queues with the same name do not share
    /// a database: SQLiteOrbit does not open shared-cache memory databases.
    public convenience init(named name: String?, configuration: Configuration) throws {
      try self.init(path: ":memory:", configuration: configuration)
    }

    public func inDatabase<T>(_ body: (Database) throws -> T) throws -> T {
      try writeWithoutTransaction(body)
    }

    /// Runs `body` in a transaction, committing or rolling back as the body requests.
    public func inTransaction(
      _ kind: Database.TransactionKind? = nil,
      _ body: (Database) throws -> Database.TransactionCompletion
    ) throws {
      try writeWithoutTransaction { db in
        try db.inTransaction(kind) { try body(db) }
      }
    }
  }

  public final class DatabasePool: DatabaseWriter, ConnectionRegistryOwner {
    public let orbitDatabase: any OrbitObservableDatabaseWriter
    let connectionRegistry = ConnectionRegistry()
    public let path: String
    public let configuration: Configuration

    public init(path: String, configuration: Configuration) throws {
      self.path = path
      self.configuration = configuration
      try configuration.checkReadonlyPath(path)
      let registry = connectionRegistry
      orbitDatabase = try translate {
        try SQLitePool(
          path: OrbitDatabasePath(path),
          configuration: configuration.resolvedNative(registry: registry),
          readerCount: configuration.maximumReaderCount
        )
      }
    }
  }

  public final class AnyDatabaseReader: DatabaseReader, ConnectionRegistryOwner {
    public let orbitDatabase: any OrbitObservableDatabaseWriter
    let connectionRegistry: ConnectionRegistry

    public init(_ reader: any DatabaseReader) {
      orbitDatabase = reader.orbitDatabase
      connectionRegistry =
        (reader as? any ConnectionRegistryOwner)?.connectionRegistry ?? ConnectionRegistry()
    }
  }

  public final class AnyDatabaseWriter: DatabaseWriter, ConnectionRegistryOwner {
    public let orbitDatabase: any OrbitObservableDatabaseWriter
    let connectionRegistry: ConnectionRegistry

    public init(_ writer: any DatabaseWriter) {
      orbitDatabase = writer.orbitDatabase
      connectionRegistry =
        (writer as? any ConnectionRegistryOwner)?.connectionRegistry ?? ConnectionRegistry()
    }
  }

  #if BuiltInSQLite
    extension DatabaseQueue {
      public convenience init() throws {
        try self.init(configuration: Configuration())
      }

      public convenience init(path: String) throws {
        try self.init(path: path, configuration: Configuration())
      }

      /// Opens a private in-memory database; see `init(named:configuration:)`.
      public convenience init(named name: String?) throws {
        try self.init(named: name, configuration: Configuration())
      }
    }

    extension DatabasePool {
      public convenience init(path: String) throws {
        try self.init(path: path, configuration: Configuration())
      }
    }
  #endif

#endif
