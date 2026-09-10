#if BuiltInSQLite
  import Foundation
  import SQLiteOrbit

  /// The build the enabled trait supplied, which tests interpose on to observe individual entry
  /// points. Naming it once here is what lets the suite run under any of them.
  var builtInTestLibrary: SQLiteLibrary {
    #if SystemSQLite
      .system
    #elseif SQLCipher
      .sqlCipher
    #elseif Turso
      .turso
    #endif
  }

  func temporaryDatabasePath(_ label: String = "db") -> String {
    NSTemporaryDirectory() + "sqlite-orbit-\(label)-\(UUID().uuidString).sqlite"
  }

  func inMemoryDatabase(
    configuration: SQLiteConfiguration = .default
  ) throws -> OrbitDatabase<SQLiteQueue> {
    OrbitDatabase(
      writer: try SQLiteQueue(path: ":memory:", configuration: configuration)
    )
  }

  func withPooledDatabase<Result>(
    configuration: SQLiteConfiguration,
    maximumReaderCount: Int = 4,
    _ body: (OrbitDatabase<SQLitePool>) async throws -> Result
  ) async throws -> Result {
    let directory = try makeShortTemporaryDirectory("pool")
    defer { try? FileManager.default.removeItem(at: directory) }

    var configuration = configuration
    configuration.readerCount = maximumReaderCount
    let pool = try SQLitePool(
      path: .file(directory.appendingPathComponent("db.sqlite")),
      configuration: configuration
    )
    return try await body(OrbitDatabase(writer: pool))
  }

  func concurrentReads<Result: Sendable>(
    _ count: Int,
    of database: OrbitDatabase<SQLitePool>,
    _ body: @escaping @Sendable (borrowing SQLiteReadTransaction) throws -> sending Result
  ) async throws -> [Result] {
    try await withThrowingTaskGroup(of: Result.self) { group in
      for _ in 0..<count {
        group.addTask { try await database.read(body) }
      }
      return try await group.reduce(into: []) { $0.append($1) }
    }
  }
#endif
