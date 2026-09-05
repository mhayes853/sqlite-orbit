#if SystemSQLite
  import Foundation
  import SQLiteOrbit

  // A unique path in the temporary directory, for a test that needs a real database file.
  func temporaryDatabasePath(_ label: String = "db") -> String {
    NSTemporaryDirectory() + "sqlite-orbit-\(label)-\(UUID().uuidString).sqlite"
  }

  // The in-memory, single-connection database most tests here want.
  func inMemoryDatabase(
    configuration: SQLiteConfiguration = .default
  ) throws -> OrbitDatabase<SQLiteQueue> {
    OrbitDatabase(
      writer: try SQLiteQueue(path: ":memory:", configuration: configuration)
    )
  }

  // Runs `body` against a file-backed pool opened with `configuration`, then deletes the file.
  //
  // A pool opens reader connections as concurrent reads demand them, which is what shows whether
  // a collation or function reached every connection rather than only the first.
  func withPooledDatabase<Result>(
    configuration: SQLiteConfiguration,
    maximumReaderCount: Int = 4,
    _ body: (OrbitDatabase<SQLitePool>) async throws -> Result
  ) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sqlite-orbit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var configuration = configuration
    configuration.readerCount = maximumReaderCount
    let pool = try SQLitePool(
      path: .file(directory.appendingPathComponent("db.sqlite")),
      configuration: configuration
    )
    return try await body(OrbitDatabase(writer: pool))
  }

  // Runs `body` on `count` concurrent reads and returns their results.
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
