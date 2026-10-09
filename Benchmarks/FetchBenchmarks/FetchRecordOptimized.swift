import Benchmark
import BenchmarkSupport
import GRDB
import SQLiteOrbit

// FetchRecordOptimizedTests: FetchRecordStruct with each library's fastest hand-written record,
// one that reads its columns by position from a selection it controls. It isolates record
// decoding without name lookup.

private struct Item: FetchableRecord, TableRecord {
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

  init(row: GRDB.Row) {
    i0 = row[0]
    i1 = row[1]
    i2 = row[2]
    i3 = row[3]
    i4 = row[4]
    i5 = row[5]
    i6 = row[6]
    i7 = row[7]
    i8 = row[8]
    i9 = row[9]
  }

  static var databaseSelection: [any SQLSelectable] {
    [
      Column("i0"),
      Column("i1"),
      Column("i2"),
      Column("i3"),
      Column("i4"),
      Column("i5"),
      Column("i6"),
      Column("i7"),
      Column("i8"),
      Column("i9")
    ]
  }
}

private struct OrbitItem: ConvertibleFromOrbitDatabaseRow {
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

  init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(
    orbitDatabaseRow row: borrowing Row
  ) throws {
    i0 = try row[0, as: Int.self]
    i1 = try row[1, as: Int.self]
    i2 = try row[2, as: Int.self]
    i3 = try row[3, as: Int.self]
    i4 = try row[4, as: Int.self]
    i5 = try row[5, as: Int.self]
    i6 = try row[6, as: Int.self]
    i7 = try row[7, as: Int.self]
    i8 = try row[8, as: Int.self]
    i9 = try row[9, as: Int.self]
  }

  // The positions above rely on this selection, as GRDB's rely on `databaseSelection`.
  static let selection: SQLiteOrbit.SQL = "SELECT i0, i1, i2, i3, i4, i5, i6, i7, i8, i9 FROM item"
}

func registerFetchRecordOptimized() {
  // GRDB's version also conforms its record to Codable and PersistableRecord, which play no part
  // in fetching, so they are left out.
  registerBenchmark(
    "FetchRecordOptimized/GRDB",
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
    "FetchRecordOptimized/Orbit",
    opening: { try OrbitConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      let items = try connection.owner.withReadConnection { connection in
        try connection.transaction { transaction in
          try transaction.fetchAll(OrbitItem.selection, as: OrbitItem.self)
        }
      }
      try expectFetchedRecords(items, i0: \.i0, i1: \.i1, i9: \.i9)
    }
  )
}
