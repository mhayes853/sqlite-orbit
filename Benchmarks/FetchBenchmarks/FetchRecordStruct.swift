import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import GRDB
import SQLiteOrbit

// FetchRecordStructTests: collects every row into an array of plain structs whose columns are
// read by name. It isolates record decoding as each library recommends writing it.

private struct Item {
  var i0: Int
  var i1: Int
  var i2: Int
  var i3: Int
  var i4: Int
  var i5: Int
  var i6: Int
  var i7: Int
  var i8: Int
  var i9: Int
}

extension Item: FetchableRecord, TableRecord {
  init(row: GRDB.Row) {
    i0 = row["i0"]
    i1 = row["i1"]
    i2 = row["i2"]
    i3 = row["i3"]
    i4 = row["i4"]
    i5 = row["i5"]
    i6 = row["i6"]
    i7 = row["i7"]
    i8 = row["i8"]
    i9 = row["i9"]
  }
}

// The macro synthesizes the by-name row initializer that GRDB's `init(row:)` spells out by hand.
@OrbitRow
private struct OrbitItem {
  var i0: Int
  var i1: Int
  var i2: Int
  var i3: Int
  var i4: Int
  var i5: Int
  var i6: Int
  var i7: Int
  var i8: Int
  var i9: Int
}

func registerFetchRecordStruct() {
  registerBenchmark(
    "FetchRecordStruct/SQLite",
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
      let columnNames = (Int32(0)..<10).map { String(cString: sqlite3_column_name(statement, $0)) }
      func index(of name: String) throws -> Int32 {
        guard let index = columnNames.firstIndex(of: name) else {
          throw BenchmarkError(message: "No column \(name)")
        }
        return Int32(index)
      }
      let index0 = try index(of: "i0")
      let index1 = try index(of: "i1")
      let index2 = try index(of: "i2")
      let index3 = try index(of: "i3")
      let index4 = try index(of: "i4")
      let index5 = try index(of: "i5")
      let index6 = try index(of: "i6")
      let index7 = try index(of: "i7")
      let index8 = try index(of: "i8")
      let index9 = try index(of: "i9")

      var items = [Item]()
      loop: while true {
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
          break loop
        case SQLITE_ROW:
          items.append(
            Item(
              i0: Int(sqlite3_column_int64(statement, index0)),
              i1: Int(sqlite3_column_int64(statement, index1)),
              i2: Int(sqlite3_column_int64(statement, index2)),
              i3: Int(sqlite3_column_int64(statement, index3)),
              i4: Int(sqlite3_column_int64(statement, index4)),
              i5: Int(sqlite3_column_int64(statement, index5)),
              i6: Int(sqlite3_column_int64(statement, index6)),
              i7: Int(sqlite3_column_int64(statement, index7)),
              i8: Int(sqlite3_column_int64(statement, index8)),
              i9: Int(sqlite3_column_int64(statement, index9))
            )
          )
        default:
          throw BenchmarkError(
            message: String(cString: sqlite3_errmsg(connection.handle))
          )
        }
      }
      try expectFetchedRecords(items, i0: \.i0, i1: \.i1, i9: \.i9)
    }
  )

  registerBenchmark(
    "FetchRecordStruct/GRDB",
    opening: { try DatabaseQueue(path: Fixture.fetchDatabasePath()) },
    measure: { dbQueue in
      let items = try dbQueue.inDatabase { db in
        try Item.fetchAll(db)
      }
      try expectFetchedRecords(items, i0: \.i0, i1: \.i1, i9: \.i9)
    }
  )

  // `fetchAll` always prepares through the statement cache.
  registerBenchmark(
    "FetchRecordStruct/Orbit",
    opening: { try OrbitConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      let items = try connection.owner.withReadConnection { connection in
        try connection.transaction { transaction in
          try transaction.fetchAll("SELECT * FROM item", as: OrbitItem.self)
        }
      }
      try expectFetchedRecords(items, i0: \.i0, i1: \.i1, i9: \.i9)
    }
  )
}
