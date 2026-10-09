import Benchmark
import BenchmarkSupport
import GRDB

// FetchRecordDecodableTests: FetchRecordStruct with a record whose row initializer Codable
// derives. GRDB only, kept so GRDB's own numbers can be read against the rest: Orbit has no
// Codable records. FetchRecordStructuredQueries is Orbit's nearest derived conformance.

private struct Item: Decodable, FetchableRecord, TableRecord {
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

func registerFetchRecordDecodable() {
  registerBenchmark(
    "FetchRecordDecodable/GRDB",
    opening: { try DatabaseQueue(path: Fixture.fetchDatabasePath()) },
    measure: { dbQueue in
      let items = try dbQueue.inDatabase { db in
        try Item.fetchAll(db)
      }
      try expectFetchedRecords(items, i0: \.i0, i1: \.i1, i9: \.i9)
    }
  )
}
