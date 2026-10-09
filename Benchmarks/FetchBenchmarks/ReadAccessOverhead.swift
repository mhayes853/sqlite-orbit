import Benchmark
import BenchmarkSupport
import GRDB
import SQLiteOrbit

// No GRDB counterpart: 10,000 one-row reads, each a database access of its own, so what is
// measured is the cost of an access (the executor hop, the transaction begun and ended around it)
// rather than of reading. The synchronous `SQLiteConnection` is the floor, with no executor at
// all.
//
// Every benchmark reads a scratch database of its own, because the pools switch theirs to WAL for
// good, and the shared fetch fixture must stay as the C API wrote it. Every implementation prepares
// the lookup through its statement cache: Orbit's `fetchOne` always does, and GRDB's through
// `cachedStatement`.

private let accessCount = 10_000
private let accessTableRowCount = 1_000

private let lookupSQL = "SELECT i0 FROM item WHERE rowid = ?"

// Row `n` stores `n` in i0, and access `i` reads row `i % 1,000 + 1`.
private let expectedLookupSum =
  accessCount / accessTableRowCount
  * (accessTableRowCount * (accessTableRowCount + 1) / 2)

private func rowID(forAccess access: Int) -> Int {
  access % accessTableRowCount + 1
}

private func makeAccessDatabase(at path: String) throws {
  let connection = try RawSQLiteConnection(path: path)
  try connection.execute(
    """
    \(Fixture.createItemTableSQL);
    WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt LIMIT \(accessTableRowCount))
    INSERT INTO item SELECT x, x, x, x, x, x, x, x, x, x FROM cnt;
    """
  )
}

private func expectLookups(sum: Int) throws {
  try expect(sum == expectedLookupSum, "Looked up values summing to \(sum)")
  blackHole(sum)
}

private struct MissingRowError: Error {}

/// Registers a benchmark against a scratch database it creates in setup and removes in teardown.
private func registerAccessBenchmark<Database>(
  _ implementation: String,
  opening open: @escaping (String) throws -> Database,
  measure body: @escaping (Database) async throws -> Void
) {
  let path = Fixture.scratchDatabasePath("read-access-\(implementation)")
  registerBenchmark(
    "ReadAccessOverhead/\(implementation)",
    opening: {
      Fixture.removeDatabase(at: path)
      try makeAccessDatabase(at: path)
      return try open(path)
    },
    cleanUp: { Fixture.removeDatabase(at: path) },
    measure: body
  )
}

func registerReadAccessOverhead() {
  registerAccessBenchmark(
    "Orbit",
    opening: { try OrbitConnection(path: $0) },
    measure: { connection in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try connection.owner.withReadConnection { connection in
          try connection.transaction { transaction in
            try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
          }
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectLookups(sum: sum)
    }
  )

  // GRDB's synchronous read, for reference: it blocks on the queue rather than suspending.
  registerAccessBenchmark(
    "GRDBQueueSync",
    opening: { try DatabaseQueue(path: $0) },
    measure: { dbQueue in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try dbQueue.read { db in
          try Int.fetchOne(db.cachedStatement(sql: lookupSQL), arguments: [id])
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectLookups(sum: sum)
    }
  )

  registerAccessBenchmark(
    "GRDBQueue",
    opening: { try DatabaseQueue(path: $0) },
    measure: { dbQueue in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try await dbQueue.read { db in
          try Int.fetchOne(db.cachedStatement(sql: lookupSQL), arguments: [id])
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectLookups(sum: sum)
    }
  )

  registerAccessBenchmark(
    "OrbitQueue",
    opening: { try SQLiteQueue(path: OrbitDatabasePath($0), configuration: .default) },
    measure: { queue in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try await queue.read { transaction in
          try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectLookups(sum: sum)
    }
  )

  // Both pools default to five readers.
  registerAccessBenchmark(
    "GRDBPool",
    opening: { try DatabasePool(path: $0) },
    measure: { dbPool in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try await dbPool.read { db in
          try Int.fetchOne(db.cachedStatement(sql: lookupSQL), arguments: [id])
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectLookups(sum: sum)
    }
  )

  registerAccessBenchmark(
    "OrbitPool",
    opening: { try SQLitePool(path: OrbitDatabasePath($0), configuration: .default) },
    measure: { pool in
      var sum = 0
      for access in 0..<accessCount {
        let id = rowID(forAccess: access)
        let value = try await pool.read { transaction in
          try transaction.fetchOne("SELECT i0 FROM item WHERE rowid = \(id)", as: Int.self)
        }
        guard let value else { throw MissingRowError() }
        sum &+= value
      }
      try expectLookups(sum: sum)
    }
  )
}
