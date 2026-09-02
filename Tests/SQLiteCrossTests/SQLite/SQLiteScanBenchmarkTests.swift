#if SystemSQLite && GRDB
  import Foundation
  import GRDB
  import StructuredQueries
  import Testing

  @testable import SQLiteCross

  /// Compares decoding a large scan through the native driver against GRDB.
  ///
  /// The native driver reaches SQLite through a table of closures rather than direct calls, which
  /// buys the ability to run against an injected build. This measures what that costs.
  ///
  /// Timing is not an assertion. The test only runs when asked, so that a loaded machine cannot
  /// fail the suite.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["SQLITE_CROSS_BENCHMARK"] != nil,
      "set SQLITE_CROSS_BENCHMARK to run"
    )
  )
  func scanningComparesWithGRDB() async throws {
    let path = NSTemporaryDirectory() + "sqlite-cross-bench-\(UUID().uuidString).sqlite"
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    let rowCount = 200_000

    let native = try SQLitePoolDriver(path: path)
    try await native.write { transaction in
      try transaction.execute(
        "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL, amount REAL NOT NULL)"
      )
      for id in 1...rowCount {
        _ = try transaction.execute(
          Item.insert { Item(id: id, title: "row \(id)", amount: Double(id) / 3) }
        )
      }
    }

    let grdb = GRDBDatabaseDriver(
      writer: try DatabasePool(path: path, configuration: .crossProcess)
    )

    func measure(_ name: String, _ body: () async throws -> Int) async rethrows {
      var best = Duration.seconds(1_000)
      for _ in 0..<3 {
        let clock = ContinuousClock()
        let start = clock.now
        let count = try await body()
        let elapsed = clock.now - start
        #expect(count == rowCount)
        best = min(best, elapsed)
      }
      print("BENCH \(name): \(best)")
    }

    try await measure("native") {
      try await native.read { transaction in
        try transaction.fetchAll(Item.all).count
      }
    }
    try await measure("grdb") {
      try await grdb.read { transaction in
        try transaction.fetchAll(Item.all).count
      }
    }
  }

  @Table
  private struct Item: Equatable, Sendable {
    let id: Int
    var title: String
    var amount: Double
  }
#endif
