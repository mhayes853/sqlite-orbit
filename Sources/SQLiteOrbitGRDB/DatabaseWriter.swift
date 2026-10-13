#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  @_spi(GRDB) import SQLiteOrbit

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
  }
  public protocol DatabaseWriter: DatabaseReader {
    @_disfavoredOverload
    func write<T>(_ updates: (Database) throws -> T) throws -> T
    func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T
    @_disfavoredOverload
    func writeWithoutTransaction<T>(_ updates: (Database) throws -> T) throws -> T
    func writeWithoutTransaction<T: Sendable>(_ updates: @Sendable (Database) throws -> T)
      async throws -> T
  }

  // Synchronous GRDB access accepts non-Sendable results and closures. These boxes transfer ownership
  // across a single synchronous call: no caller can use the captured state until that call returns.
  private struct SynchronousTransfer<Value>: @unchecked Sendable { let value: Value }
  extension DatabaseReader {
    public var path: String {
      guard let info = (orbitDatabase as? any SQLiteGRDBDatabaseMetadata)?.grdbDatabaseInfo else {
        preconditionFailure("the custom Orbit driver does not expose database metadata")
      }
      return info.path.sqlitePath
    }
    public var configuration: Configuration {
      guard let info = (orbitDatabase as? any SQLiteGRDBDatabaseMetadata)?.grdbDatabaseInfo else {
        preconditionFailure("the custom Orbit driver does not expose database metadata")
      }
      return Configuration(native: info.configuration, readerCount: info.readerCount)
    }
    @_disfavoredOverload
    public func read<T>(_ value: (Database) throws -> T) throws -> T {
      try withoutActuallyEscaping(value) { value in
        let operation = SynchronousTransfer(value: value)
        return try translate {
          try orbitDatabase.readBlocking { transaction in
            try transaction.withGRDBAccess {
              SynchronousTransfer(value: try operation.value(Database($0)))
            }
          }
          .value
        }
      }
    }
    public func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
      try await translate {
        try await orbitDatabase.read { transaction in
          try transaction.withGRDBAccess { try value(Database($0)) }
        }
      }
    }
    @_disfavoredOverload
    public func unsafeRead<T>(_ value: (Database) throws -> T) throws -> T {
      try withoutActuallyEscaping(value) { value in
        let operation = SynchronousTransfer(value: value)
        return try translate {
          try orbitDatabase.readWithoutTransactionBlocking { connection in
            try connection.withGRDBAccess {
              SynchronousTransfer(value: try operation.value(Database($0)))
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
          try connection.withGRDBAccess { try value(Database($0)) }
        }
      }
    }
    public func asyncRead(_ value: @escaping @Sendable (Result<Database, Error>) -> Void) {
      Task {
        do { try await read { value(.success($0)) } } catch { value(.failure(error)) }
      }
    }
  }
  extension DatabaseWriter {
    @_disfavoredOverload
    public func write<T>(_ updates: (Database) throws -> T) throws -> T {
      try withoutActuallyEscaping(updates) { updates in
        let operation = SynchronousTransfer(value: updates)
        return try translate {
          try orbitDatabase.writeBlocking { transaction in
            try transaction.withGRDBAccess {
              SynchronousTransfer(value: try operation.value(Database($0)))
            }
          }
          .value
        }
      }
    }
    public func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
      try await translate {
        try await orbitDatabase.write { transaction in
          try transaction.withGRDBAccess { try updates(Database($0)) }
        }
      }
    }
    @_disfavoredOverload
    public func writeWithoutTransaction<T>(_ updates: (Database) throws -> T) throws -> T {
      try withoutActuallyEscaping(updates) { updates in
        let operation = SynchronousTransfer(value: updates)
        return try translate {
          try orbitDatabase.writeWithoutTransactionBlocking { connection in
            try connection.withGRDBAccess {
              SynchronousTransfer(value: try operation.value(Database($0)))
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
          try connection.withGRDBAccess { try updates(Database($0)) }
        }
      }
    }
    public func erase() throws {
      try write { db in
        let tables = try String.fetchAll(
          db,
          sql: "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
        for table in tables { try db.execute(sql: "DROP TABLE \(quoted(table))") }
      }
    }
  }

  extension SQLiteOrbit.SQLiteQueue: DatabaseWriter {
    public var orbitDatabase: any OrbitObservableDatabaseWriter { self }
  }
  extension SQLiteOrbit.SQLitePool: DatabaseWriter {
    public var orbitDatabase: any OrbitObservableDatabaseWriter { self }
  }
  extension SQLiteOrbit.OrbitIPCDatabase: DatabaseWriter {
    public var orbitDatabase: any OrbitObservableDatabaseWriter { self }
  }
  #if Turso
    extension SQLiteOrbit.TursoPool: DatabaseWriter {
      public var orbitDatabase: any OrbitObservableDatabaseWriter { self }
    }
  #endif

  public struct Configuration: Sendable {
    private(set) var native: SQLiteConfiguration
    public var maximumReaderCount = 5
    public var foreignKeysEnabled: Bool {
      get { native.isForeignKeysEnabled }
      set { native.isForeignKeysEnabled = newValue }
    }
    public var library: SQLiteLibrary {
      get { native.library }
      set { native.library = newValue }
    }
    public var busyMode: Database.BusyMode {
      get {
        switch native.busyPolicy {
        case .handler(let callback): return .callback(callback)
        case .waitIndefinitely: return .timeout(Double(Int32.max) / 1000)
        case .timeout(let duration):
          if duration == .zero { return .immediateError }
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
    }
    #if BuiltInSQLite
      public init() { self.init(library: SQLiteConfiguration.default.library) }
    #endif
    public mutating func prepareDatabase(_ setup: @escaping @Sendable (Database) throws -> Void) {
      native.setups.append(
        SQLiteSetup { connection in
          try connection.withGRDBAccess { try setup(Database($0)) }
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
      case callback(@Sendable (Int) -> Bool)
    }
  }
  public final class DatabaseQueue: DatabaseWriter {
    public let orbitDatabase: any OrbitObservableDatabaseWriter
    public let path: String
    public let configuration: Configuration
    public convenience init(configuration: Configuration) throws {
      try self.init(path: ":memory:", configuration: configuration)
    }
    public init(path: String, configuration: Configuration) throws {
      self.path = path
      self.configuration = configuration
      orbitDatabase = try translate {
        try SQLiteQueue(path: OrbitDatabasePath(path), configuration: configuration.native)
      }
    }
    public func inDatabase<T>(_ body: (Database) throws -> T) throws -> T {
      try writeWithoutTransaction(body)
    }
  }
  public final class DatabasePool: DatabaseWriter {
    public let orbitDatabase: any OrbitObservableDatabaseWriter
    public let path: String
    public let configuration: Configuration
    public init(path: String, configuration: Configuration) throws {
      self.path = path
      self.configuration = configuration
      orbitDatabase = try translate {
        try SQLitePool(
          path: OrbitDatabasePath(path),
          configuration: configuration.native,
          readerCount: configuration.maximumReaderCount
        )
      }
    }
  }
  public final class AnyDatabaseReader: DatabaseReader {
    public let orbitDatabase: any OrbitObservableDatabaseWriter
    public init(_ reader: any DatabaseReader) { orbitDatabase = reader.orbitDatabase }
  }
  public final class AnyDatabaseWriter: DatabaseWriter {
    public let orbitDatabase: any OrbitObservableDatabaseWriter
    public init(_ writer: any DatabaseWriter) { orbitDatabase = writer.orbitDatabase }
  }

  #if BuiltInSQLite
    extension DatabaseQueue {
      public convenience init() throws { try self.init(configuration: Configuration()) }
      public convenience init(path: String) throws {
        try self.init(path: path, configuration: Configuration())
      }
    }
    extension DatabasePool {
      public convenience init(path: String) throws {
        try self.init(path: path, configuration: Configuration())
      }
    }
  #endif

#endif
