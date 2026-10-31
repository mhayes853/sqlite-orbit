// Shared application fixtures, run against both the overlay and GRDB 7.11.1.
import Foundation
import SQLiteOrbitGRDB
import XCTest

private enum AsyncWriteError: Error { case expected }
private final class WriteResult {
  let count: Int
  init(_ count: Int) { self.count = count }
}

class AsyncWriteSurfaceTests: GRDBTestCase {
  func testCompletionUsesTheWriterAfterCommitAndAcceptsNonSendableResults() throws {
    let database = try makeDatabaseQueue()
    let done = expectation(description: "completion")
    database.asyncWrite { db in
      XCTAssertTrue(db.isInsideTransaction)
      try db.execute(sql: "CREATE TEMP TABLE temp_result(n); INSERT INTO temp_result VALUES (42)")
      return WriteResult(42)
    } completion: { db, result in
      XCTAssertFalse(db.isInsideTransaction)
      do {
        XCTAssertEqual(try result.get().count, 42)
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT n FROM temp_result"), 42)
        // Completion still owns the writer, and may perform further database work.
        try db.execute(sql: "INSERT INTO temp_result VALUES (43)")
      } catch { XCTFail("Unexpected error: \(error)") }
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    XCTAssertEqual(
      try database.read { try Int.fetchAll($0, sql: "SELECT n FROM temp_result") },
      [42, 43]
    )
  }

  func testThrownUpdatesRollBackBeforeCompletion() throws {
    let database = try makeDatabaseQueue()
    try database.write { try $0.execute(sql: "CREATE TABLE item(n)") }
    let done = expectation(description: "rollback")
    database.asyncWrite { db -> Int in
      try db.execute(sql: "INSERT INTO item VALUES (1)")
      throw AsyncWriteError.expected
    } completion: { db, result in
      XCTAssertFalse(db.isInsideTransaction)
      if case .failure(let error) = result {
        XCTAssertTrue(error is AsyncWriteError)
      } else {
        XCTFail("Expected failure")
      }
      do {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item")
        XCTAssertEqual(count, 0)
      } catch { XCTFail("Unexpected error: \(error)") }
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
  }

  func testCommitFailureIsReportedAfterRollback() throws {
    let database = try makeDatabaseQueue()
    try database.write { db in
      try db.execute(
        sql:
          "CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(parentId REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)"
      )
    }
    let done = expectation(description: "failed commit")
    database.asyncWrite { db in
      try db.execute(sql: "INSERT INTO child VALUES (1)")
      return "uncommitted"
    } completion: { db, result in
      XCTAssertFalse(db.isInsideTransaction)
      if case .failure(let error) = result {
        XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
      } else {
        XCTFail("Expected failed commit")
      }
      do {
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM child"), 0)
        try db.execute(sql: "INSERT INTO parent VALUES (1)")
      } catch { XCTFail("Unexpected error: \(error)") }
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    XCTAssertEqual(
      try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM parent") },
      1
    )
  }

  func testWithoutTransactionRetainsStatementsBeforeAnError() throws {
    let database = try makeDatabaseQueue()
    let done = expectation(description: "partial write")
    database.asyncWriteWithoutTransaction { db in
      XCTAssertFalse(db.isInsideTransaction)
      do {
        try db.execute(sql: "CREATE TABLE item(n); INSERT INTO item VALUES (1)")
        try db.execute(sql: "INSERT INTO missing VALUES (2)")
        XCTFail("Expected SQL error")
      } catch { XCTAssertTrue(error is DatabaseError) }
      do {
        try db.inTransaction {
          XCTAssertTrue(db.isInsideTransaction)
          try db.execute(sql: "INSERT INTO item VALUES (2)")
          return .rollback
        }
      } catch { XCTFail("Unexpected error: \(error)") }
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    XCTAssertEqual(try database.read { try Int.fetchAll($0, sql: "SELECT n FROM item") }, [1])
  }

  func testOptionalNilResultIsSuccessful() throws {
    let database = try makeDatabaseQueue()
    let done = expectation(description: "nil result")
    database.asyncWrite { _ -> Int? in
      nil
    } completion: { _, result in
      switch result {
      case .success(let value): XCTAssertNil(value)
      case .failure(let error): XCTFail("Unexpected error: \(error)")
      }
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
  }
}
