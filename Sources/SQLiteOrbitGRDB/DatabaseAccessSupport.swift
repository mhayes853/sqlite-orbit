#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  // MARK: - Connection registry

  /// The connections opened by a compatibility database, for `interrupt()`.
  ///
  /// SQLiteOrbit drivers keep their connections open for their whole lifetime, so the handles
  /// remain valid as long as the database that registered them.
  final class ConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var connections:
      [(pointer: OpaquePointer, interrupt: @Sendable (OpaquePointer?) -> Void)] =
        []

    func register(_ connection: OpaquePointer, library: SQLiteLibrary) {
      lock.withLock {
        guard !connections.contains(where: { $0.pointer == connection }) else { return }
        connections.append((connection, library.connections.interrupt))
      }
    }

    // Forgets the connections of a closed database, which may be closed at any time.
    func removeAll() {
      lock.withLock { connections = [] }
    }

    func interruptAll() {
      for connection in lock.withLock({ connections }) {
        connection.interrupt(connection.pointer)
      }
    }
  }

  protocol ConnectionRegistryOwner {
    var connectionRegistry: ConnectionRegistry { get }
  }

  // MARK: - Reentrancy

  // The accesses running on the current thread, innermost last, so that reentrant accesses can
  // reuse their connection.
  private enum AccessStack {
    final class Box {
      var entries: [(database: ObjectIdentifier, db: Database, isWriter: Bool)] = []
    }

    static var box: Box {
      let dictionary = Thread.current.threadDictionary
      let key = "SQLiteOrbitGRDB.AccessStack"
      if let box = dictionary[key] as? Box { return box }
      let box = Box()
      dictionary[key] = box
      return box
    }
  }

  /// The innermost compatibility access running on the current thread, if any.
  func currentThreadDatabase() -> Database? {
    AccessStack.box.entries.last?.db
  }

  extension DatabaseReader {
    func enterAccess<T>(
      _ access: SQLiteScopedAccess,
      isWriter: Bool,
      _ body: (Database) throws -> T
    ) throws -> T {
      let db = Database(access)
      db.enableRawStatements()
      let box = AccessStack.box
      box.entries.append((ObjectIdentifier(orbitDatabase), db, isWriter))
      defer {
        box.entries.removeLast()
        db.finalizeRawStatements()
      }
      return try body(db)
    }

    func currentDatabase(requiringWriter: Bool) -> Database? {
      let id = ObjectIdentifier(orbitDatabase)
      return AccessStack.box.entries.last {
        $0.database == id && (!requiringWriter || $0.isWriter)
      }?
      .db
    }

    /// Runs `value` with the connection of the enclosing access on this database, or in a new
    /// access without a transaction.
    public func unsafeReentrantRead<T>(_ value: (Database) throws -> T) throws -> T {
      if let db = currentDatabase(requiringWriter: false) {
        return try value(db)
      }
      // As in GRDB, reads from a database queue use its only connection, which can write.
      if let queue = self as? DatabaseQueue {
        return try queue.unsafeReentrantWrite(value)
      }
      return try unsafeRead(value)
    }

    /// Interrupts the statements running on the connections of this database.
    ///
    /// Only databases opened by `DatabaseQueue` and `DatabasePool` (or wrappers of them) can be
    /// interrupted; other drivers ignore this call.
    public func interrupt() {
      (self as? any ConnectionRegistryOwner)?.connectionRegistry.interruptAll()
    }
  }

  extension DatabaseWriter {
    /// Runs `updates` with the writer connection of the enclosing access on this database, or
    /// in a new access without a transaction.
    public func unsafeReentrantWrite<T>(_ updates: (Database) throws -> T) throws -> T {
      if let db = currentDatabase(requiringWriter: true) {
        return try updates(db)
      }
      return try writeWithoutTransaction(updates)
    }
  }

  extension DatabasePool {
    /// Frees as much memory as possible from the connections of the pool.
    public func releaseMemory() {
      _ = try? writeWithoutTransaction { try $0.execute(sql: "PRAGMA shrink_memory") }
    }

    /// Frees memory from the connections of the pool, without blocking.
    public func releaseMemoryEventually() {
      asyncWriteWithoutTransaction { _ = try? $0.execute(sql: "PRAGMA shrink_memory") }
    }

    /// SQLiteOrbit keeps pool readers open; this method has no effect.
    public func invalidateReadOnlyConnections() {}
  }

  extension DatabaseQueue {
    /// Frees as much memory as possible from the connection.
    public func releaseMemory() {
      _ = try? writeWithoutTransaction { try $0.execute(sql: "PRAGMA shrink_memory") }
    }
  }
#endif

#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // MARK: - Smaller GRDB conveniences

  extension ColumnInfo: FetchableRecord {
    /// Creates column information from a row of `PRAGMA table_info`.
    public init(row: Row) {
      self.init(
        cid: row["cid"],
        name: row["name"],
        type: row["type"],
        notNull: row["notnull"],
        defaultValueSQL: row["dflt_value"],
        primaryKeyIndex: row["pk"]
      )
    }
  }

  /// Identifies a database schema: main, temp, or an attached database.
  public enum DatabaseSchemaID: Hashable, Sendable {
    case main
    case temp
    case attached(String)

    /// The name of the schema in SQL, such as `main`.
    public var name: String {
      switch self {
      case .main: "main"
      case .temp: "temp"
      case .attached(let name): name
      }
    }

    /// The name of the schema table, such as `"main".sqlite_master`.
    public var schemaTableName: String {
      switch self {
      case .main: "main.sqlite_master"
      case .temp: "temp.sqlite_master"
      case .attached(let name): name.quotedDatabaseIdentifier + ".sqlite_master"
      }
    }
  }

  /// Identifies a schema object, such as a table, in a database schema.
  public struct DatabaseObjectID: Hashable, Sendable {
    public var name: String
    public var schemaID: DatabaseSchemaID

    public init(name: String, schemaID: DatabaseSchemaID) {
      self.name = name
      self.schemaID = schemaID
    }
  }

  extension Database {
    /// SQLiteOrbitGRDB does not cache schema information; this method has no effect.
    public func clearSchemaCache() {}

    /// Frees as much memory as possible from the connection.
    public func releaseMemory() {
      _ = try? execute(sql: "PRAGMA shrink_memory")
    }

    /// The maximum number of arguments of a statement.
    public var maximumStatementArgumentCount: Int {
      (try? Int.fetchOne(self, sql: "SELECT sqlite_version() >= '3.32'")) == 1 ? 32766 : 999
    }
  }

  extension Database: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
      connectionState.databaseDescription ?? configuration.label ?? "GRDB.Database"
    }

    public var debugDescription: String {
      "<Database: \(description)>"
    }
  }

  extension DatabaseWriter {
    /// Schedules updates outside of a transaction, while no read runs.
    public func asyncBarrierWriteWithoutTransaction(
      _ updates: @escaping @Sendable (Result<Database, Error>) -> Void
    ) {
      asyncWriteWithoutTransaction { updates(.success($0)) }
    }
  }

  extension DatabasePool {
    /// Runs `updates` in a transaction, committing or rolling back as the body requests.
    public func writeInTransaction(
      _ kind: Database.TransactionKind? = nil,
      _ updates: (Database) throws -> Database.TransactionCompletion
    ) throws {
      try writeWithoutTransaction { db in
        try db.inTransaction(kind) { try updates(db) }
      }
    }
  }
#endif

#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  // MARK: - Closing

  /// Holds the native driver of a database until it is closed.
  final class DriverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var driver: any OrbitObservableDatabaseWriter

    init(_ driver: any OrbitObservableDatabaseWriter) {
      self.driver = driver
    }

    var current: any OrbitObservableDatabaseWriter {
      lock.withLock { driver }
    }

    var isClosed: Bool {
      current is ClosedOrbitDatabase
    }

    // Releases the native driver, which closes its connections once outstanding accesses end.
    func close(metadata: SQLiteDatabaseMetadata?) {
      lock.withLock {
        guard !(driver is ClosedOrbitDatabase) else { return }
        driver = ClosedOrbitDatabase(metadata: metadata)
      }
    }
  }

  protocol ClosableDatabase {
    var driver: DriverBox { get }
  }

  // The driver of a closed database: every access fails with SQLITE_MISUSE, as in GRDB.
  final class ClosedOrbitDatabase: OrbitDatabaseWriter, OrbitObservableDatabase, @unchecked Sendable
  {
    let databaseMetadata: SQLiteDatabaseMetadata?

    init(metadata: SQLiteDatabaseMetadata?) {
      databaseMetadata = metadata
    }

    private var error: SQLiteError {
      SQLiteError(code: .misuse, message: "Connection is closed")
    }

    func read<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) async throws -> Result { throw error }

    func readBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) throws -> Result { throw error }

    func readWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) async throws -> Result { throw error }

    func readWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadConnection) throws -> Result
    ) throws -> Result { throw error }

    func write<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) async throws -> Result { throw error }

    func writeBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) throws -> Result { throw error }

    func writeWithoutTransaction<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) async throws -> Result { throw error }

    func writeWithoutTransactionBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteConnection) throws -> Result
    ) throws -> Result { throw error }

    func subscribe(
      transactionObserver: any OrbitDatabaseTransactionObserver,
      region: OrbitDatabaseRegion
    ) throws -> OrbitRegionSubscription { throw error }
  }

  extension DatabaseReader {
    /// Closes the database. Later accesses fail with `SQLITE_MISUSE`; closing again does nothing.
    ///
    /// The native driver is released, and closes its connections when outstanding accesses and
    /// observations end. Snapshots close their own connection. Other drivers ignore this call.
    public func close() throws {
      if let closable = self as? any ClosableDatabase {
        (self as? any ConnectionRegistryOwner)?.connectionRegistry.removeAll()
        closable.driver.close(metadata: orbitDatabase.databaseMetadata)
      } else if let snapshot = self as? DatabaseSnapshot {
        try snapshot.close()
      }
    }
  }
#endif
