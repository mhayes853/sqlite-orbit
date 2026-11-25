import Benchmark
import BenchmarkSupport
import SQLiteOrbit

// Orbit's record insert: a Structured Queries `@Table` model, with no GRDB counterpart of its own.
// Compare it with InsertRecordStruct and InsertRecordOptimized.
@Table("item")
struct TableItem {
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

  init(_ i: Int) {
    (i0, i1, i2, i3, i4, i5, i6, i7, i8, i9) = (i, i, i, i, i, i, i, i, i, i)
  }
}

// Ten bound values a row keep a statement of 1,000 rows at 10,000 variables, inside SQLite's
// default limit of 32,766; all 50,000 rows at once would exceed it.
private let batchRowCount = 1_000

func insertRecordStructuredQueriesBenchmarks() {
  // One `INSERT` a row, built anew each time and run through the connection's statement cache.
  Benchmark("InsertRecordStructuredQueries/Orbit") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          for i in 0..<Fixture.insertedRowCount {
            try TableItem.insert { TableItem(i) }.execute(transaction)
          }
        }
      }
    }
  }

  // One `prepareInsert`, built once from the table's columns and run with each record.
  Benchmark("InsertRecordStructuredQueries/OrbitPrepared") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          var insert = try transaction.prepareInsert(TableItem.self)
          for i in 0..<Fixture.insertedRowCount {
            try insert.execute(TableItem(i))
          }
        }
      }
    }
  }

  // `transaction.insert(_:)` for each record: the table's cached plan and the connection's cached
  // statement, with nothing prepared by the caller.
  Benchmark("InsertRecordStructuredQueries/OrbitInsert") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          for i in 0..<Fixture.insertedRowCount {
            try transaction.insert(TableItem(i))
          }
        }
      }
    }
  }

  // `transaction.insert(contentsOf:)` over every record, made lazily as it is read.
  Benchmark("InsertRecordStructuredQueries/OrbitContentsOfLazy") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          _ = try transaction.insert(
            contentsOf: (0..<Fixture.insertedRowCount).lazy.map { TableItem($0) }
          )
        }
      }
    }
  }

  // The same over an array, built inside the measurement as the lazy records are.
  Benchmark("InsertRecordStructuredQueries/OrbitContentsOfArray") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          _ = try transaction.insert(
            contentsOf: (0..<Fixture.insertedRowCount).map { TableItem($0) }
          )
        }
      }
    }
  }

  // The same, with every statement prepared anew.
  Benchmark("InsertRecordStructuredQueries/OrbitUncached") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          for i in 0..<Fixture.insertedRowCount {
            try transaction.execute(
              SQLiteOrbit.SQL(fragment: TableItem.insert { TableItem(i) }.query),
              cached: false
            )
          }
        }
      }
    }
  }

  // One multi-row `INSERT` per `batchRowCount` rows.
  Benchmark("InsertRecordStructuredQueriesBatch/Orbit") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          for start in stride(from: 0, to: Fixture.insertedRowCount, by: batchRowCount) {
            let end = min(start + batchRowCount, Fixture.insertedRowCount)
            let items = (start..<end).map(TableItem.init)
            try TableItem.insert { items }.execute(transaction)
          }
        }
      }
    }
  }
}
