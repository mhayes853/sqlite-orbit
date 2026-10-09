import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import GRDB
import SQLiteOrbit

// FetchNamedValuesTests: FetchPositionalValues with every column found by name. It isolates the
// cost of name lookup on top of value extraction.
//
// GRDB's file has no C baseline. The one here resolves the ten names to indices once per
// statement, as the C baseline of GRDB's FetchRecordStructTests does, which is the floor a name
// lookup can reach.
func registerFetchNamedValues() {
  registerBenchmark(
    "FetchNamedValues/SQLite",
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
      let columnNames = (Int32(0)..<sqlite3_column_count(statement))
        .map {
          String(cString: sqlite3_column_name(statement, $0))
        }
      let indices = try (0..<10)
        .map { column in
          guard let index = columnNames.firstIndex(of: "i\(column)") else {
            throw BenchmarkError(message: "No column i\(column)")
          }
          return Int32(index)
        }
      var count = 0
      var sum = 0
      loop: while true {
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
          break loop
        case SQLITE_ROW:
          for index in indices {
            sum &+= Int(sqlite3_column_int64(statement, index))
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
    "FetchNamedValues/GRDB",
    opening: { try DatabaseQueue(path: Fixture.fetchDatabasePath()) },
    measure: { dbQueue in
      let (count, sum) = try dbQueue.inDatabase { db in
        var count = 0
        var sum = 0
        let rows = try GRDB.Row.fetchCursor(db, sql: "SELECT * FROM item")
        while let row = try rows.next() {
          sum &+= row["i0"] as Int
          sum &+= row["i1"] as Int
          sum &+= row["i2"] as Int
          sum &+= row["i3"] as Int
          sum &+= row["i4"] as Int
          sum &+= row["i5"] as Int
          sum &+= row["i6"] as Int
          sum &+= row["i7"] as Int
          sum &+= row["i8"] as Int
          sum &+= row["i9"] as Int
          count += 1
        }
        return (count, sum)
      }
      try expectFetchedValues(count: count, sum: sum)
    }
  )

  registerBenchmark(
    "FetchNamedValues/Orbit",
    opening: { try OrbitConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      let (count, sum) = try connection.owner.withReadConnection { connection in
        try connection.transaction { transaction in
          try sumNamedValues(in: transaction)
        }
      }
      try expectFetchedValues(count: count, sum: sum)
    }
  )

  registerBenchmark(
    "FetchNamedValues/OrbitQueue",
    opening: { try SQLiteQueue(path: OrbitDatabasePath(Fixture.fetchDatabasePath())) },
    measure: { (queue: SQLiteQueue) async throws in
      let (count, sum) = try await queue.read { transaction in
        try sumNamedValues(in: transaction)
      }
      try expectFetchedValues(count: count, sum: sum)
    }
  )
}

// Prepared through the statement cache (`cached: true`); see FetchPositionalValues.
private func sumNamedValues(
  in transaction: borrowing SQLiteReadTransaction
) throws -> (count: Int, sum: Int) {
  var count = 0
  var sum = 0
  var cursor = try transaction.rowCursor("SELECT * FROM item", cached: true)
  while let row = try cursor.next() {
    sum &+= try row[column: "i0", as: Int.self]
    sum &+= try row[column: "i1", as: Int.self]
    sum &+= try row[column: "i2", as: Int.self]
    sum &+= try row[column: "i3", as: Int.self]
    sum &+= try row[column: "i4", as: Int.self]
    sum &+= try row[column: "i5", as: Int.self]
    sum &+= try row[column: "i6", as: Int.self]
    sum &+= try row[column: "i7", as: Int.self]
    sum &+= try row[column: "i8", as: Int.self]
    sum &+= try row[column: "i9", as: Int.self]
    count += 1
  }
  return (count, sum)
}
