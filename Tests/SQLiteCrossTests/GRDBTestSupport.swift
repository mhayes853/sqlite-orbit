#if GRDB
  import Foundation
  import GRDB
  import SQLiteCross

  /// Runs `body` against a file-backed pool with `extensions` registered, then deletes the file.
  ///
  /// A pool opens reader connections as concurrent reads demand them, which is what shows whether
  /// an extension reached every connection rather than only the first.
  func withPooledDatabase<Result>(
    extensions: DatabaseExtensions,
    maximumReaderCount: Int = 4,
    _ body: (CrossProcessDatabase<GRDBDatabaseDriver>) async throws -> Result
  ) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sqlite-cross-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var configuration = Configuration()
    configuration.maximumReaderCount = maximumReaderCount
    configuration.register(extensions)
    let pool = try DatabasePool(
      path: directory.appendingPathComponent("db.sqlite").path,
      configuration: configuration
    )
    return try await body(CrossProcessDatabase(writer: pool))
  }

  /// Runs `body` on `count` concurrent reads and returns their results.
  func concurrentReads<Result: Sendable>(
    _ count: Int,
    of database: CrossProcessDatabase<GRDBDatabaseDriver>,
    _ body: @escaping @Sendable (borrowing GRDBReadTransaction) throws -> sending Result
  ) async throws -> [Result] {
    try await withThrowingTaskGroup(of: Result.self) { group in
      for _ in 0..<count {
        group.addTask { try await database.read(body) }
      }
      return try await group.reduce(into: []) { $0.append($1) }
    }
  }
#endif
