#if SystemSQLite
  import Foundation
  import StructuredQueries
  import Testing

  @testable import SQLiteOrbit

  /// Compares decoding a large scan through the native pool and queue implementations.
  ///
  /// Both reach SQLite through an injectable table of closures, keeping the native scan path under
  /// measurement for both local scheduling strategies.
  ///
  /// Timing is not an assertion. The test only runs when asked, so that a loaded machine cannot
  /// fail the suite.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["SQLITE_ORBIT_BENCHMARK"] != nil,
      "set SQLITE_ORBIT_BENCHMARK to run"
    )
  )
  func scanningComparesNativePoolAndQueue() async throws {
    let path = NSTemporaryDirectory() + "sqlite-orbit-bench-\(UUID().uuidString).sqlite"
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    let rowCount = 200_000

    let pool = try SQLitePoolDriver(path: DatabasePath(path))
    try await pool.write { transaction in
      try transaction.execute(
        "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL, amount REAL NOT NULL)"
      )
      for id in 1...rowCount {
        _ = try transaction.execute(
          Item.insert { Item(id: id, title: "row \(id)", amount: Double(id) / 3) }
        )
      }
    }

    let queue = try SQLiteQueueDriver(path: DatabasePath(path))

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

    try await measure("pool") {
      try await pool.read { transaction in
        try transaction.fetchAll(Item.all).count
      }
    }
    try await measure("queue") {
      try await queue.read { transaction in
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
