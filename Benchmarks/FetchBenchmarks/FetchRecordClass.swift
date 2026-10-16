import Benchmark
import BenchmarkSupport
import GRDB

// FetchRecordClassTests: FetchRecordStruct with a subclass of GRDB's `Record`, which also keeps a
// copy of its row to tell whether it has changed since it was fetched. GRDB only, kept so GRDB's
// own numbers can be read against the rest: Orbit has no record class.

private class Item: Record {
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

  override class var databaseTableName: String {
    "item"
  }

  required init(row: GRDB.Row) throws {
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
    try super.init(row: row)
  }
}

func registerFetchRecordClass() {
  registerBenchmark(
    "FetchRecordClass/GRDB",
    opening: { try DatabaseQueue(path: Fixture.fetchDatabasePath()) },
    measure: { dbQueue in
      let items = try dbQueue.inDatabase { db in
        try Item.fetchAll(db)
      }
      try expectFetchedRecords(items, i0: \.i0, i1: \.i1, i9: \.i9)
    }
  )
}
