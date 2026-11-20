import Benchmark
import BenchmarkSupport
import GRDB
import SQLiteOrbit

// 50,000 records inserted in one transaction through one prepared statement they bind themselves
// to, GRDB's recipe for batch inserts, for parity with GRDB's own numbers.
private struct Item: Codable, FetchableRecord, PersistableRecord {
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

  static func optimizedInsertStatement(_ db: Database) throws -> GRDB.Statement {
    try db.makeStatement(
      literal: """
        INSERT INTO \(self) (
          \(CodingKeys.i0),
          \(CodingKeys.i1),
          \(CodingKeys.i2),
          \(CodingKeys.i3),
          \(CodingKeys.i4),
          \(CodingKeys.i5),
          \(CodingKeys.i6),
          \(CodingKeys.i7),
          \(CodingKeys.i8),
          \(CodingKeys.i9))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    )
  }

  func insert(with statement: GRDB.Statement) throws {
    statement.setUncheckedArguments([i0, i1, i2, i3, i4, i5, i6, i7, i8, i9])
    try statement.execute()
  }
}

func insertRecordOptimizedBenchmarks() {
  Benchmark("InsertRecordOptimized/GRDB") { benchmark in
    try measureInsert(benchmark, open: { try DatabaseQueue(path: $0) }) { dbQueue in
      try dbQueue.inTransaction { db in
        let statement = try Item.optimizedInsertStatement(db)
        for i in 0..<Fixture.insertedRowCount {
          let item = Item(i0: i, i1: i, i2: i, i3: i, i4: i, i5: i, i6: i, i7: i, i8: i, i9: i)
          try item.insert(with: statement)
        }
        return .commit
      }
    }
  }

  // Orbit's counterpart: one prepared statement, bound by hand from each record's fields.
  Benchmark("InsertRecordOptimized/Orbit") { benchmark in
    try measureInsert(benchmark, open: openOrbitConnection) { owner in
      try owner.withWriteConnection { connection in
        try connection.transaction { transaction in
          var insert = try transaction.prepare(SQLiteOrbit.SQL(text: Fixture.insertItemSQL))
          for i in 0..<Fixture.insertedRowCount {
            let item = Item(i0: i, i1: i, i2: i, i3: i, i4: i, i5: i, i6: i, i7: i, i8: i, i9: i)
            try insert.execute(
              item.i0, item.i1, item.i2, item.i3, item.i4,
              item.i5, item.i6, item.i7, item.i8, item.i9
            )
          }
        }
      }
    }
  }
}
