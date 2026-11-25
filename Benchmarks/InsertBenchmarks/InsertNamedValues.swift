import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import GRDB

// 50,000 rows of ten integers in one transaction, binding arguments by name. Orbit has no entry:
// it binds interpolated values by position and has no API that binds parameters by name, so its
// numbers for this workload are InsertPositionalValues'.
func insertNamedValuesBenchmarks() {
  let insertSQL = """
    INSERT INTO item (i0, i1, i2, i3, i4, i5, i6, i7, i8, i9) \
    VALUES (:i0, :i1, :i2, :i3, :i4, :i5, :i6, :i7, :i8, :i9)
    """

  // GRDB's file has no C version. This one looks every parameter up by name for every row, as
  // GRDB's dictionary of arguments must, using static strings so the lookup allocates nothing.
  Benchmark("InsertNamedValues/SQLite") { benchmark in
    let names: [StaticString] = [
      ":i0", ":i1", ":i2", ":i3", ":i4", ":i5", ":i6", ":i7", ":i8", ":i9"
    ]
    try measureInsert(benchmark, open: RawSQLiteConnection.init(path:)) { connection in
      try connection.execute("BEGIN TRANSACTION")
      let statement = try connection.prepare(insertSQL)
      for i in Int64(0)..<Int64(Fixture.insertedRowCount) {
        sqlite3_reset(statement)
        for name in names {
          let index = name.withUTF8Buffer { buffer in
            buffer.withMemoryRebound(to: CChar.self) {
              sqlite3_bind_parameter_index(statement, $0.baseAddress)
            }
          }
          sqlite3_bind_int64(statement, index, i)
        }
        try connection.step(statement)
      }
      sqlite3_finalize(statement)
      try connection.execute("COMMIT")
    }
  }

  Benchmark("InsertNamedValues/GRDB") { benchmark in
    try measureInsert(benchmark, open: { try DatabaseQueue(path: $0) }) { dbQueue in
      try dbQueue.inTransaction { db in
        let statement = try db.makeStatement(sql: insertSQL)
        for i in 0..<Fixture.insertedRowCount {
          try statement.execute(arguments: [
            "i0": i, "i1": i, "i2": i, "i3": i, "i4": i, "i5": i, "i6": i, "i7": i, "i8": i, "i9": i
          ])
        }
        return .commit
      }
    }
  }
}
