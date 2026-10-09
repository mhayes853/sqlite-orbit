import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import GRDB
import SQLiteOrbit

// 50,000 rows of ten integers in one transaction, binding arguments by position. SQLite and GRDB
// reuse one prepared statement. `Orbit` runs the documented `execute`, which finds the statement in
// the connection's cache; `OrbitUncached` passes `cached: false`, preparing every row's statement
// anew, so the gap between the two is the cost of preparing.
func insertPositionalValuesBenchmarks() {
  Benchmark("InsertPositionalValues/SQLite") { benchmark in
    try measureInsert(benchmark, open: RawSQLiteConnection.init(path:)) { connection in
      try connection.execute("BEGIN TRANSACTION")
      let statement = try connection.prepare(Fixture.insertItemSQL)
      for i in Int64(0)..<Int64(Fixture.insertedRowCount) {
        sqlite3_reset(statement)
        for column in Int32(1)...10 {
          sqlite3_bind_int64(statement, column, i)
        }
        try connection.step(statement)
      }
      sqlite3_finalize(statement)
      try connection.execute("COMMIT")
    }
  }

  Benchmark("InsertPositionalValues/GRDB") { benchmark in
    try measureInsert(benchmark, open: { try DatabaseQueue(path: $0) }) { dbQueue in
      try dbQueue.inTransaction { db in
        let statement = try db.makeStatement(sql: Fixture.insertItemSQL)
        for i in 0..<Fixture.insertedRowCount {
          statement.setUncheckedArguments([i, i, i, i, i, i, i, i, i, i])
          try statement.execute()
        }
        return .commit
      }
    }
  }

  Benchmark("InsertPositionalValues/Orbit") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          for i in 0..<Fixture.insertedRowCount {
            try transaction.execute(insertItemSQL(i))
          }
        }
      }
    }
  }

  Benchmark("InsertPositionalValues/OrbitUncached") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          for i in 0..<Fixture.insertedRowCount {
            try transaction.execute(insertItemSQL(i), cached: false)
          }
        }
      }
    }
  }

  // The documented `execute`, like `Orbit`, so the two differ only by the queue's hop to its
  // connection's executor.
  Benchmark("InsertPositionalValues/OrbitQueue") { benchmark in
    try await measureInsert(
      benchmark,
      open: { try SQLiteQueue(path: OrbitDatabasePath($0), configuration: .default) }
    ) { queue in
      try await queue.write { transaction in
        for i in 0..<Fixture.insertedRowCount {
          try transaction.execute(insertItemSQL(i))
        }
      }
    }
  }
}
