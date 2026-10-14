// Shared application fixture, run against both the overlay and GRDB 7.11.1.
import XCTest
import SQLiteOrbitGRDB

class ScopedWriteTests: GRDBTestCase {
  func testTransactionKindsCommitAndRollBack() throws {
    let queue = try makeDatabaseQueue()
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "CREATE TABLE t(id INTEGER)")
      let kinds: [Database.TransactionKind] = [.deferred, .immediate, .exclusive]
      for kind in kinds {
        try db.inTransaction(kind) {
          XCTAssertTrue(db.isInsideTransaction)
          try db.execute(sql: "INSERT INTO t VALUES (1)")
          return .commit
        }
        try db.inTransaction(kind) {
          try db.execute(sql: "INSERT INTO t VALUES (2)")
          return .rollback
        }
        XCTAssertFalse(db.isInsideTransaction)
      }
      XCTAssertEqual(try Int.fetchAll(db, sql: "SELECT id FROM t"), [1, 1, 1])
    }
  }
  func testLimitsApplyToBulkWrites() throws {
    let queue = try makeDatabaseQueue()
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY, score INTEGER); INSERT INTO t VALUES(1,10),(2,20),(3,30)")
      let table = Table<Row>("t")
      let supported = try Bool.fetchOne(db, sql: "SELECT sqlite_compileoption_used('ENABLE_UPDATE_DELETE_LIMIT')")!
      if supported {
        XCTAssertEqual(try table.all().order(Column("id").desc).limit(1).updateAll(db, Column("score").set(to: 99)), 1)
        XCTAssertEqual(try Int.fetchAll(db, sql: "SELECT score FROM t ORDER BY id"), [10,20,99])
        XCTAssertEqual(try table.all().order(Column("id")).limit(1, offset: 1).deleteAll(db), 1)
        XCTAssertEqual(try Int.fetchAll(db, sql: "SELECT id FROM t ORDER BY id"), [1,3])
      } else {
        XCTAssertThrowsError(try table.all().order(Column("id").desc).limit(1).updateAll(db, Column("score").set(to: 99)))
        XCTAssertThrowsError(try table.all().order(Column("id")).limit(1).deleteAll(db))
        XCTAssertEqual(try Int.fetchAll(db, sql: "SELECT score FROM t ORDER BY id"), [10,20,30])
      }
    }
  }
  func testRepeatedKeyFiltersIntersect() throws {
    let queue = try makeDatabaseQueue()
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY); INSERT INTO t VALUES(1),(2)")
      XCTAssertEqual(try Table<Row>("t").all().filter(key: 1).filter(key: 2).fetchCount(db), 0)
    }
  }
  func testCompositeKeysApplyToLimitedDeletes() throws {
    let queue = try makeDatabaseQueue()
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE t(a INTEGER, b INTEGER, PRIMARY KEY(a,b)); INSERT INTO t VALUES(1,1),(1,2),(2,1)")
      let supported = try Bool.fetchOne(db, sql: "SELECT sqlite_compileoption_used('ENABLE_UPDATE_DELETE_LIMIT')")!
      if supported {
        XCTAssertEqual(try Table<Row>("t").all().order(Column("a"), Column("b")).limit(1).deleteAll(db), 1)
        XCTAssertEqual(try Table<Row>("t").fetchCount(db), 2)
      } else {
        XCTAssertThrowsError(try Table<Row>("t").all().order(Column("a"), Column("b")).limit(1).deleteAll(db))
        XCTAssertEqual(try Table<Row>("t").fetchCount(db), 3)
      }
    }
  }
}
