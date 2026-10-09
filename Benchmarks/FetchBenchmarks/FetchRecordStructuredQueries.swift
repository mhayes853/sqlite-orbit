import Benchmark
import BenchmarkSupport
import SQLiteOrbit

// Orbit's counterpart to FetchRecordDecodable, which has no GRDB test of its own: a record whose
// decoding is derived for it, here by Structured Queries' `@Table`, fetched through the query
// builder. It isolates the builder's column-by-column decoder against FetchRecordStruct's
// hand-written and macro-written by-name initializers.

@Table("item")
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

func registerFetchRecordStructuredQueries() {
  // `fetchAll` always prepares through the statement cache.
  registerBenchmark(
    "FetchRecordStructuredQueries/Orbit",
    opening: { try OrbitConnection(path: Fixture.fetchDatabasePath()) },
    measure: { connection in
      let items = try connection.owner.withReadConnection { connection in
        try connection.transaction { transaction in
          try transaction.fetchAll(Item.all)
        }
      }
      try expectFetchedRecords(items, i0: \.i0, i1: \.i1, i9: \.i9)
    }
  )
}
