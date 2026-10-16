import Benchmark
import BenchmarkSupport
import GRDB

// 50,000 `Encodable` records inserted one at a time in one transaction, for parity with GRDB's own
// numbers.
private struct Item: Encodable, PersistableRecord {
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

func insertRecordEncodableBenchmarks() {
  Benchmark("InsertRecordEncodable/GRDB") { benchmark in
    try measureInsert(benchmark, open: { try DatabaseQueue(path: $0) }) { dbQueue in
      try dbQueue.inTransaction { db in
        for i in 0..<Fixture.insertedRowCount {
          try Item(i0: i, i1: i, i2: i, i3: i, i4: i, i5: i, i6: i, i7: i, i8: i, i9: i).insert(db)
        }
        return .commit
      }
    }
  }
}
