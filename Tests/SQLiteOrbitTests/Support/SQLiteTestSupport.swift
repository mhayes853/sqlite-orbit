#if BuiltInSQLite
  import Foundation

  @testable import SQLiteOrbit

  /// A database either SQLite driver opens, which is what a test run against every driver works
  /// with.
  typealias SQLiteTestDatabase = any OrbitMultiprocessDatabaseWriter & OrbitObservableDatabase

  /// The SQLite drivers a test can run against, which is how one runs against every one of them.
  ///
  /// ```swift
  /// @Test(arguments: SQLiteTestDriver.allCases)
  /// func writesAreReadBack(_ driver: SQLiteTestDriver) async throws {
  ///   try await driver.withDatabase(schema: "CREATE TABLE items (id INTEGER PRIMARY KEY)") {
  ///     database in
  ///     try await database.execute(sql: "INSERT INTO items (id) VALUES (1)")
  ///     #expect(try await database.rowCount(of: "items") == 1)
  ///   }
  /// }
  /// ```
  enum SQLiteTestDriver: CaseIterable, Sendable {
    case queue
    case pool

    /// Where the driver's database lives in `directory`.
    func path(in directory: URL) -> OrbitDatabasePath {
      TestDatabaseFile(in: directory).path
    }

    /// Opens the database in `directory` with this driver.
    func open(
      in directory: URL,
      configuration: SQLiteConfiguration = .default
    ) throws -> SQLiteTestDatabase {
      try TestDatabaseFile(in: directory).open(self, configuration: configuration)
    }

    /// Opens the database in `directory` with this driver, and creates the table `items`, with an
    /// integer primary key `id` and nothing else.
    func openWithItems(in directory: URL) async throws -> SQLiteTestDatabase {
      let database = try self.open(in: directory)
      try await database.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
      return database
    }

    /// Runs `body` with a database this driver opens in a temporary directory of its own, which
    /// is removed once `body` returns.
    ///
    /// - Parameters:
    ///   - configuration: The configuration to open the database with.
    ///   - schema: SQL to run in a write transaction before `body`, if any.
    ///   - body: Receives the database.
    /// - Returns: Whatever `body` returns.
    func withDatabase<Result>(
      configuration: SQLiteConfiguration = .default,
      schema: String? = nil,
      isolation: isolated (any Actor)? = #isolation,
      _ body: (SQLiteTestDatabase) async throws -> Result
    ) async throws -> Result {
      try await withTestDatabaseFile { file in
        let database = try file.open(self, configuration: configuration)
        if let schema { try await database.execute(sql: schema) }
        return try await body(database)
      }
    }
  }

  /// A database file in a temporary directory of its own, which a test opens with whichever
  /// driver it is about, as often as it likes.
  ///
  /// Everything SQLite puts beside the file — its journal, its WAL and shared memory, a Turso
  /// log — is in the same directory, so removing the directory leaves nothing behind.
  ///
  /// ```swift
  /// try await withTestDatabaseFile { file in
  ///   let writer = try file.pool()
  ///   let peer = try file.queue()
  ///   ...
  /// }
  /// ```
  struct TestDatabaseFile: Sendable {
    /// The directory the database is in, and nothing else.
    let directory: URL

    /// Names the database file in `directory`, which need not exist yet.
    init(in directory: URL) {
      self.directory = directory
    }

    /// The database file.
    var url: URL { self.directory.appending(component: "database.sqlite") }

    /// The database file, as the drivers take it.
    var path: OrbitDatabasePath { .file(self.url) }

    /// Opens the database with a ``SQLiteQueue``.
    func queue(configuration: SQLiteConfiguration = .default) throws -> SQLiteQueue {
      try SQLiteQueue(path: self.path, configuration: configuration)
    }

    /// Opens the database with a ``SQLitePool``.
    func pool(configuration: SQLiteConfiguration = .default) throws -> SQLitePool {
      try SQLitePool(path: self.path, configuration: configuration)
    }

    /// Opens the database with `driver`.
    func open(
      _ driver: SQLiteTestDriver,
      configuration: SQLiteConfiguration = .default
    ) throws -> SQLiteTestDatabase {
      switch driver {
      case .queue: try self.queue(configuration: configuration)
      case .pool: try self.pool(configuration: configuration)
      }
    }

    #if Turso
      /// Opens the database with a ``TursoPool``.
      func tursoPool(
        configuration: SQLiteConfiguration = .turso,
        writerCount: Int = 4
      ) throws -> TursoPool {
        try TursoPool(path: self.path, configuration: configuration, writerCount: writerCount)
      }
    #endif

    #if canImport(Darwin) || os(Linux) || os(Android)
      /// The coordination directory ``ipcDatabase(configuration:)`` opens the database through,
      /// beside the database file.
      var coordination: UnixDatagramIPCTransport.Configuration {
        UnixDatagramIPCTransport.Configuration(directory: self.directory.appending(path: "c"))
      }

      /// Opens the database with an ``OrbitIPCDatabase``, coordinating through ``coordination``.
      func ipcDatabase(configuration: SQLiteConfiguration = .default) throws -> OrbitIPCDatabase {
        try OrbitIPCDatabase(
          path: self.path,
          configuration: configuration,
          coordination: self.coordination
        )
      }
    #endif

    /// The names of the files in the directory, sorted, for a test of what a driver leaves
    /// behind.
    func fileNames() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: self.directory.path).sorted()
    }
  }

  /// Runs `body` with a database file in a temporary directory of its own, which is removed once
  /// `body` returns or throws.
  ///
  /// - Parameters:
  ///   - label: A name for what the directory is for, as ``makeShortTemporaryDirectory(_:)``
  ///     takes.
  ///   - body: Receives the file, which does not exist yet.
  /// - Returns: Whatever `body` returns.
  func withTestDatabaseFile<Result>(
    _ label: String = "db",
    _ body: (TestDatabaseFile) throws -> Result
  ) throws -> Result {
    try withTemporaryDirectory(label) { try body(TestDatabaseFile(in: $0)) }
  }

  /// Runs `body` with a database file in a temporary directory of its own, as the synchronous
  /// ``withTestDatabaseFile(_:_:)`` does, for a body that suspends.
  func withTestDatabaseFile<Result>(
    _ label: String = "db",
    isolation: isolated (any Actor)? = #isolation,
    _ body: (TestDatabaseFile) async throws -> Result
  ) async throws -> Result {
    try await withTemporaryDirectory(label) { try await body(TestDatabaseFile(in: $0)) }
  }

  // MARK: - Raw SQL

  // Tests about a driver rather than about the queries it runs set up, and look at, their
  // databases with plain SQL. These spell that in one line, each in a transaction of its own.

  extension OrbitDatabaseWriter {
    /// Runs `sql`, which may hold several statements, in a write transaction of its own.
    func execute(sql: String) async throws {
      try await self.write { try $0.executeScript(sql) }
    }

    /// Runs `sql`, which may hold several statements, in a write transaction of its own,
    /// blocking the calling thread.
    func executeBlocking(sql: String) throws {
      try self.writeBlocking { try $0.executeScript(sql) }
    }
  }

  /// A value a test reads out of a column with the plain-SQL helpers below.
  protocol TestColumnValue: Sendable {
    init?(testColumn value: OrbitDatabaseValue)
  }

  extension Int: TestColumnValue {
    init?(testColumn value: OrbitDatabaseValue) {
      guard let integer = value.integerValue else { return nil }
      self.init(integer)
    }
  }

  extension Int64: TestColumnValue {
    init?(testColumn value: OrbitDatabaseValue) {
      guard let integer = value.integerValue else { return nil }
      self = integer
    }
  }

  extension Double: TestColumnValue {
    init?(testColumn value: OrbitDatabaseValue) {
      guard let real = value.realValue else { return nil }
      self = real
    }
  }

  extension Bool: TestColumnValue {
    init?(testColumn value: OrbitDatabaseValue) {
      guard let integer = value.integerValue else { return nil }
      self = integer != 0
    }
  }

  extension String: TestColumnValue {
    init?(testColumn value: OrbitDatabaseValue) {
      guard let text = value.textValue else { return nil }
      self = text
    }
  }

  extension OrbitDatabaseRow where Self: ~Copyable, Self: ~Escapable {
    /// The first column, read as `Value`, or `nil` when it is `NULL` or of another type.
    func first<Value: TestColumnValue>(as type: Value.Type) -> Value? {
      Value(testColumn: self[0])
    }
  }

  extension OrbitDatabaseReadTransaction where Self: ~Copyable, Self: ~Escapable {
    /// Fetches the first column of every row `sql` produces. A row whose column is not a `Value`
    /// is left out.
    func fetchAll<Value: TestColumnValue>(_ sql: SQL, as type: Value.Type) throws -> [Value] {
      try fetchAll(sql) { $0.first(as: Value.self) }.compactMap { $0 }
    }

    /// Fetches the first column of the first row `sql` produces.
    func fetchOne<Value: TestColumnValue>(_ sql: SQL, as type: Value.Type) throws -> Value? {
      try fetchOne(sql) { $0.first(as: Value.self) } ?? nil
    }
  }

  extension OrbitDatabaseReader {
    /// Fetches the first column of every row the query `sql` produces, in a read transaction of
    /// its own. A row whose column is not a `Value` is left out.
    func fetchAll<Value: TestColumnValue>(
      sql: String,
      as type: Value.Type
    ) async throws -> [Value] {
      try await self.read { transaction in
        try transaction.fetchAll("\(raw: sql)") { $0.first(as: Value.self) }.compactMap { $0 }
      }
    }

    /// Fetches the first column of the first row the query `sql` produces, in a read transaction
    /// of its own.
    func fetchOne<Value: TestColumnValue>(
      sql: String,
      as type: Value.Type
    ) async throws -> Value? {
      try await self.read { transaction in
        try transaction.fetchOne("\(raw: sql)") { $0.first(as: Value.self) } ?? nil
      }
    }

    /// Fetches the first column of the first row the query `sql` produces, in a read transaction
    /// of its own, blocking the calling thread.
    func fetchOneBlocking<Value: TestColumnValue>(
      sql: String,
      as type: Value.Type
    ) throws -> Value? {
      try self.readBlocking { transaction in
        try transaction.fetchOne("\(raw: sql)") { $0.first(as: Value.self) } ?? nil
      }
    }

    /// Counts the rows of `table`.
    func rowCount(of table: String) async throws -> Int {
      try await self.fetchOne(sql: "SELECT count(*) FROM \(table)", as: Int.self) ?? 0
    }

    /// The names of the tables the schema holds, SQLite's own left out, sorted.
    func tableNames() async throws -> [String] {
      try await self.fetchAll(
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
          ORDER BY name
          """,
        as: String.self
      )
    }

    /// The value of the pragma `name`, as a reading connection sees it.
    ///
    /// The pragma is read through its table-valued function, since SQLite reports a pragma such
    /// as `journal_mode`, which can also set the mode, as one that may write.
    func pragma<Value: TestColumnValue>(
      _ name: String,
      as type: Value.Type
    ) async throws -> Value? {
      try await self.fetchOne(sql: "SELECT * FROM pragma_\(name)", as: Value.self)
    }
  }
#endif
