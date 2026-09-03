#if SystemSQLite
  import Foundation
  import SQLiteCross

  /// Runs `body` against a file-backed pool opened with `configuration`, then deletes the file.
  ///
  /// A pool opens reader connections as concurrent reads demand them, which is what shows whether
  /// a collation or function reached every connection rather than only the first.
  func withPooledDatabase<Result>(
    configuration: SQLiteConfiguration,
    maximumReaderCount: Int = 4,
    _ body: (SQLiteCrossDatabase) async throws -> Result
  ) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sqlite-cross-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var configuration = configuration
    configuration.readerCount = maximumReaderCount
    let pool = try SQLitePoolDriver(
      path: .file(directory.appendingPathComponent("db.sqlite")),
      configuration: configuration
    )
    return try await body(CrossProcessDatabase(driver: pool))
  }

  /// Runs `body` on `count` concurrent reads and returns their results.
  func concurrentReads<Result: Sendable>(
    _ count: Int,
    of database: SQLiteCrossDatabase,
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
