import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import GRDB
import SQLiteOrbit

// FetchPositionalValuesTests: walks every row without collecting any, reading ten integers by
// column index. It isolates row stepping and value extraction.
//
// Values are summed rather than discarded, in every implementation alike, so the reads cannot be
// optimized away and the sum checks them. Orbit prepares through its statement cache
// (`cached: true`), while GRDB and the C baseline prepare each iteration as GRDB's tests do; one
// preparation is negligible next to 200,000 steps.
func registerFetchPositionalValues() {
  registerBenchmark(
    "FetchPositionalValues/SQLite",
    opening: { try RawSQLiteConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(connection.handle, "SELECT * FROM item", -1, &statement, nil)
          == SQLITE_OK
      else {
        throw BenchmarkError(
          message: String(cString: sqlite3_errmsg(connection.handle))
        )
      }
      defer { sqlite3_finalize(statement) }
      var count = 0
      var sum = 0
      loop: while true {
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
          break loop
        case SQLITE_ROW:
          for column in Int32(0)..<10 {
            sum &+= Int(sqlite3_column_int64(statement, column))
          }
          count += 1
        default:
          throw BenchmarkError(
            message: String(cString: sqlite3_errmsg(connection.handle))
          )
        }
      }
      try expectFetchedValues(count: count, sum: sum)
    }
  )

  registerBenchmark(
    "FetchPositionalValues/GRDB",
    opening: { try DatabaseQueue(path: Fixture.fetchDatabasePath()) },
    measure: { dbQueue in
      let (count, sum) = try dbQueue.inDatabase { db in
        var count = 0
        var sum = 0
        let rows = try GRDB.Row.fetchCursor(db, sql: "SELECT * FROM item")
        while let row = try rows.next() {
          sum &+= row[0] as Int
          sum &+= row[1] as Int
          sum &+= row[2] as Int
          sum &+= row[3] as Int
          sum &+= row[4] as Int
          sum &+= row[5] as Int
          sum &+= row[6] as Int
          sum &+= row[7] as Int
          sum &+= row[8] as Int
          sum &+= row[9] as Int
          count += 1
        }
        return (count, sum)
      }
      try expectFetchedValues(count: count, sum: sum)
    }
  )

  registerBenchmark(
    "FetchPositionalValues/Orbit",
    opening: { try OrbitConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      let (count, sum) = try connection.owner.withReadConnection { connection in
        try connection.transaction { transaction in
          try sumPositionalValues(in: transaction)
        }
      }
      try expectFetchedValues(count: count, sum: sum)
    }
  )

  registerBenchmark(
    "FetchPositionalValues/OrbitQueue",
    opening: { try SQLiteQueue(path: OrbitDatabasePath(Fixture.fetchDatabasePath())) },
    measure: { (queue: SQLiteQueue) async throws in
      let (count, sum) = try await queue.read { transaction in
        try sumPositionalValues(in: transaction)
      }
      try expectFetchedValues(count: count, sum: sum)
    }
  )
}

private func sumPositionalValues(
  in transaction: borrowing SQLiteReadTransaction
) throws -> (count: Int, sum: Int) {
  var count = 0
  var sum = 0
  var cursor = try transaction.rowCursor("SELECT * FROM item", cached: true)
  while let row = try cursor.next() {
    sum &+= try row[0, as: Int.self]
    sum &+= try row[1, as: Int.self]
    sum &+= try row[2, as: Int.self]
    sum &+= try row[3, as: Int.self]
    sum &+= try row[4, as: Int.self]
    sum &+= try row[5, as: Int.self]
    sum &+= try row[6, as: Int.self]
    sum &+= try row[7, as: Int.self]
    sum &+= try row[8, as: Int.self]
    sum &+= try row[9, as: Int.self]
    count += 1
  }
  return (count, sum)
}
