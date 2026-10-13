import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import GRDB
import SQLiteOrbit

// No GRDB counterpart: 100,000 one-row lookups by rowid inside a single read, each reading one
// integer. With a single step per statement, what is measured is the cost of running a statement
// (preparing or fetching it from a cache, binding, resetting, decoding one value) rather than of
// stepping through rows, which the other fetch groups isolate.
//
// The implementations cover each library's ways of running the same lookup:
// - Prepared once per iteration and rebound for every lookup: `SQLite`, `GRDBPrepared`, and
//   `OrbitPrepared`.
// - Fetched from a statement cache by SQL: `GRDBCached` (opt-in, through `cachedStatement`) and
//   `Orbit` (the default for ad-hoc SQL).
// - Prepared anew for every lookup: `SQLiteUncached`, `GRDB` and `GRDBLiteral` (the default for
//   ad-hoc SQL), `GRDBQueryInterface`, and `OrbitUncached`.
// - Built with a query builder: `GRDBQueryInterface` and `OrbitStructuredQueries`, which differ in
//   that Orbit's goes through its statement cache.

private let lookupCount = 100_000

private let lookupSQL = "SELECT i1 FROM item WHERE rowid = ?"

// Lookup `k` reads value `k * stride % rowCount`, from row `value + 1`. The stride is prime, so
// coprime with the row count, and scatters the lookups over the table without repeating a row.
private let lookupStride = 104_729

private func rowID(forLookup lookup: Int) -> Int {
  lookup &* lookupStride % Fixture.fetchedRowCount + 1
}

private let expectedLookupSum = (0..<lookupCount).reduce(0) { $0 + rowID(forLookup: $1) - 1 }

private func expectLookups(sum: Int) throws {
  try expect(sum == expectedLookupSum, "Looked up values summing to \(sum)")
  blackHole(sum)
}

private struct MissingRowError: Error {}

/// The fixture's table to GRDB's query interface, which looks rows up by rowid when the table has
/// no primary key.
private struct GRDBItem: TableRecord {
  static let databaseTableName = "item"
}

/// The fixture's table to Structured Queries, with only the column looked up.
@Table("item")
private struct OrbitItem {
  var i1: Int
}

func registerFetchOneByRowID() {
  registerBenchmark(
    "FetchOneByRowID/SQLite",
    opening: { try RawSQLiteConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      try connection.execute("BEGIN")
      let statement = try connection.prepare(lookupSQL)
      defer { sqlite3_finalize(statement) }
      var sum = 0
      for lookup in 0..<lookupCount {
        sqlite3_reset(statement)
        sqlite3_bind_int64(statement, 1, Int64(rowID(forLookup: lookup)))
        sum &+= try stepOneInteger(statement, connection: connection)
      }
      try connection.execute("COMMIT")
      try expectLookups(sum: sum)
    }
  )

  registerBenchmark(
    "FetchOneByRowID/SQLiteUncached",
    opening: { try RawSQLiteConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      try connection.execute("BEGIN")
      var sum = 0
      for lookup in 0..<lookupCount {
        let statement = try connection.prepare(lookupSQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(rowID(forLookup: lookup)))
        sum &+= try stepOneInteger(statement, connection: connection)
      }
      try connection.execute("COMMIT")
      try expectLookups(sum: sum)
    }
  )

  // GRDB's ad-hoc fetches, which prepare a statement for every call.
  registerGRDBLookups("GRDB") { db, id in
    try Int.fetchOne(db, sql: lookupSQL, arguments: [id])
  }

  // GRDB has no `fetchOne(_:literal:)`; an interpolated `SQLRequest` is its literal form.
  registerGRDBLookups("GRDBLiteral") { db, id in
    try SQLRequest<Int>(literal: "SELECT i1 FROM item WHERE rowid = \(id)").fetchOne(db)
  }

  registerGRDBLookups("GRDBCached") { db, id in
    try Int.fetchOne(db.cachedStatement(sql: lookupSQL), arguments: [id])
  }

  registerBenchmark(
    "FetchOneByRowID/GRDBPrepared",
    opening: { try DatabaseQueue(path: Fixture.fetchDatabasePath()) },
    measure: { dbQueue in
      let sum = try dbQueue.read { db in
        let statement = try db.makeStatement(sql: lookupSQL)
        var sum = 0
        for lookup in 0..<lookupCount {
          guard let value = try Int.fetchOne(statement, arguments: [rowID(forLookup: lookup)])
          else { throw MissingRowError() }
          sum &+= value
        }
        return sum
      }
      try expectLookups(sum: sum)
    }
  )

  registerGRDBLookups("GRDBQueryInterface") { db, id in
    try GRDBItem.select(Column("i1"), as: Int.self).filter(key: id).fetchOne(db)
  }

  registerOrbitLookups("Orbit") { transaction, id in
    try transaction.fetchOne("SELECT i1 FROM item WHERE rowid = \(id)", as: Int.self)
  }

  // `fetchOne` has no `cached:` parameter, so this opens the cursor it would and reads its first
  // row.
  registerOrbitLookups("OrbitUncached") { transaction, id in
    var cursor = try transaction.rowCursor(
      "SELECT i1 FROM item WHERE rowid = \(id)",
      cached: false
    )
    return try cursor.first(as: Int.self)
  }

  registerBenchmark(
    "FetchOneByRowID/OrbitPrepared",
    opening: { try OrbitConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      let sum = try connection.owner.withReadConnection { connection in
        try connection.transaction { transaction in
          var lookupStatement = try transaction.prepare("SELECT i1 FROM item WHERE rowid = ?")
          var sum = 0
          for lookup in 0..<lookupCount {
            guard let value = try lookupStatement.fetchOne(rowID(forLookup: lookup), as: Int.self)
            else { throw MissingRowError() }
            sum &+= value
          }
          return sum
        }
      }
      try expectLookups(sum: sum)
    }
  )

  // The query builder renders its SQL for every lookup and runs it through the statement cache.
  registerOrbitLookups("OrbitStructuredQueries") { transaction, id in
    try OrbitItem.where { $0.rowid.eq(id) }.select(\.i1).fetchOne(transaction)
  }
}

/// Registers GRDB lookups that each run `fetch` in one `read`.
private func registerGRDBLookups(
  _ implementation: String,
  fetch: @escaping (GRDB.Database, Int) throws -> Int?
) {
  registerBenchmark(
    "FetchOneByRowID/\(implementation)",
    opening: { try DatabaseQueue(path: Fixture.fetchDatabasePath()) },
    measure: { dbQueue in
      let sum = try dbQueue.read { db in
        var sum = 0
        for lookup in 0..<lookupCount {
          guard let value = try fetch(db, rowID(forLookup: lookup)) else {
            throw MissingRowError()
          }
          sum &+= value
        }
        return sum
      }
      try expectLookups(sum: sum)
    }
  )
}

/// Registers Orbit lookups that each run `fetch` in one read transaction.
private func registerOrbitLookups(
  _ implementation: String,
  fetch: @escaping (borrowing SQLiteReadTransaction, Int) throws -> Int?
) {
  registerBenchmark(
    "FetchOneByRowID/\(implementation)",
    opening: { try OrbitConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      let sum = try connection.owner.withReadConnection { connection in
        try connection.transaction { transaction in
          var sum = 0
          for lookup in 0..<lookupCount {
            guard let value = try fetch(transaction, rowID(forLookup: lookup)) else {
              throw MissingRowError()
            }
            sum &+= value
          }
          return sum
        }
      }
      try expectLookups(sum: sum)
    }
  )
}

/// Steps a lookup to its row and returns its first column.
private func stepOneInteger(
  _ statement: OpaquePointer,
  connection: RawSQLiteConnection
) throws -> Int {
  guard sqlite3_step(statement) == SQLITE_ROW else {
    throw BenchmarkError(message: String(cString: sqlite3_errmsg(connection.handle)))
  }
  return Int(sqlite3_column_int64(statement, 0))
}
