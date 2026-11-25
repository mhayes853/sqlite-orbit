import Benchmark
import BenchmarkSupport
import GRDB

// 50,000 `PersistableRecord` structs inserted one at a time in one transaction, for parity with
// GRDB's own numbers. Orbit's record insert is InsertRecordStructuredQueries.
private struct Item: PersistableRecord {
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

  func encode(to container: inout PersistenceContainer) {
    container["i0"] = i0
    container["i1"] = i1
    container["i2"] = i2
    container["i3"] = i3
    container["i4"] = i4
    container["i5"] = i5
    container["i6"] = i6
    container["i7"] = i7
    container["i8"] = i8
    container["i9"] = i9
  }
}

func insertRecordStructBenchmarks() {
  Benchmark("InsertRecordStruct/GRDB") { benchmark in
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
