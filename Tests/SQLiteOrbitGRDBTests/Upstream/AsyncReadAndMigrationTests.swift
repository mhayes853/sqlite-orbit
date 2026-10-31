// Shared application fixtures, run against both the overlay and GRDB 7.11.1.
// Based on GRDB's unsafe-read contract and DatabaseMigratorTests callback scenarios.
import Dispatch
import Foundation
import SQLiteOrbitGRDB
import XCTest

private enum CallbackMigrationError: Error { case expected }

class AsyncReadAndMigrationTests: GRDBTestCase {
  func testUnsafeReadIsAsynchronousAndOutsideATransaction() throws {
    for writer: any DatabaseWriter in [try makeDatabaseQueue(), try makeDatabasePool()] {
      try writer.write { try $0.execute(sql: "CREATE TABLE item(n); INSERT INTO item VALUES (42)") }
      let reader = AnyDatabaseReader(writer)
      let done = expectation(description: "unsafe read")
      let scheduled = DispatchSemaphore(value: 0)
      reader.asyncUnsafeRead { result in
        scheduled.wait()
        do {
          let db = try result.get()
          XCTAssertFalse(db.isInsideTransaction)
          let value = try Int.fetchOne(db, sql: "SELECT n FROM item")
          XCTAssertEqual(value, 42)
        } catch { XCTFail("Unexpected error: \(error)") }
        done.fulfill()
      }
      scheduled.signal()
      wait(for: [done], timeout: 5)
    }
  }

  func testUnsafeReadHandlesSQLFailureAndSchedulesAnotherRead() throws {
    let database = try makeDatabaseQueue()
    let done = expectation(description: "second read")
    database.asyncUnsafeRead { result in
      do {
        let db = try result.get()
        do {
          try db.execute(sql: "This is not SQL")
          XCTFail("Expected SQL error")
        } catch let error as DatabaseError {
          XCTAssertEqual(error.sql, "This is not SQL")
        }
      } catch { XCTFail("Unexpected error: \(error)") }
      database.asyncRead { result in
        do {
          let db = try result.get()
          XCTAssertTrue(db.isInsideTransaction)
          let value = try Int.fetchOne(db, sql: "SELECT 42")
          XCTAssertEqual(value, 42)
        } catch { XCTFail("Unexpected error: \(error)") }
        done.fulfill()
      }
    }
    wait(for: [done], timeout: 5)
  }

  func testEmptyMigratorCompletionCanWrite() throws {
    for writer: any DatabaseWriter in [try makeDatabaseQueue(), try makeDatabasePool()] {
      let done = expectation(description: "empty migrator")
      DatabaseMigrator()
        .asyncMigrate(writer) { result in
          do {
            let db = try result.get()
            XCTAssertFalse(db.isInsideTransaction)
            try db.execute(
              sql: "CREATE TABLE after_migration(n); INSERT INTO after_migration VALUES (42)"
            )
          } catch { XCTFail("Unexpected error: \(error)") }
          done.fulfill()
        }
      wait(for: [done], timeout: 5)
      XCTAssertEqual(
        try writer.read { try Int.fetchOne($0, sql: "SELECT n FROM after_migration") },
        42
      )
    }
  }

  func testMigrationCompletionCanChainAndDoesNotRepeatAppliedMigrations() throws {
    for writer: any DatabaseWriter in [try makeDatabaseQueue(), try makeDatabasePool()] {
      var migrator = DatabaseMigrator()
      migrator.registerMigration("create") { db in
        XCTAssertTrue(db.isInsideTransaction)
        try db.execute(sql: "CREATE TABLE item(n); INSERT INTO item VALUES (1)")
      }
      migrator.registerMigration("append") { db in
        try db.execute(sql: "INSERT INTO item VALUES (2)")
      }
      let completed = migrator
      let done = expectation(description: "migrated twice")
      completed.asyncMigrate(writer) { result in
        do {
          let db = try result.get()
          XCTAssertFalse(db.isInsideTransaction)
          let values = try Int.fetchAll(db, sql: "SELECT n FROM item ORDER BY n")
          XCTAssertEqual(values, [1, 2])
          let identifiers = try completed.appliedMigrations(db)
          XCTAssertEqual(identifiers, ["create", "append"])
          let foreignKeys = try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
          XCTAssertEqual(foreignKeys, true)
        } catch { XCTFail("Unexpected error: \(error)") }
        completed.asyncMigrate(writer) { result in
          do {
            let values = try Int.fetchAll(result.get(), sql: "SELECT n FROM item ORDER BY n")
            XCTAssertEqual(values, [1, 2])
          } catch { XCTFail("Unexpected error: \(error)") }
          done.fulfill()
        }
      }
      wait(for: [done], timeout: 5)
    }
  }

  func testFailedMigrationRollsBackAndRetainsEarlierMigrations() throws {
    for writer: any DatabaseWriter in [try makeDatabaseQueue(), try makeDatabasePool()] {
      var migrator = DatabaseMigrator()
      migrator.registerMigration("create") { db in
        try db.execute(sql: "CREATE TABLE item(n); INSERT INTO item VALUES (1)")
      }
      migrator.registerMigration("fail") { db in
        try db.execute(sql: "INSERT INTO item VALUES (2)")
        throw CallbackMigrationError.expected
      }
      let completed = migrator
      let done = expectation(description: "failed migration")
      completed.asyncMigrate(writer) { result in
        if case .failure(let error) = result {
          XCTAssertTrue(error is CallbackMigrationError)
        } else {
          XCTFail("Expected migration error")
        }
        writer.asyncRead { result in
          do {
            let db = try result.get()
            let values = try Int.fetchAll(db, sql: "SELECT n FROM item")
            XCTAssertEqual(values, [1])
            let identifiers = try completed.appliedMigrations(db)
            XCTAssertEqual(identifiers, ["create"])
          } catch { XCTFail("Unexpected error: \(error)") }
          done.fulfill()
        }
      }
      wait(for: [done], timeout: 5)
    }
  }

  func testMigrationSQLFailureIsADatabaseError() throws {
    let database = try makeDatabaseQueue()
    var migrator = DatabaseMigrator()
    migrator.registerMigration("fail") { try $0.execute(sql: "This is not SQL") }
    let done = expectation(description: "SQL failure")
    migrator.asyncMigrate(database) { result in
      if case .failure(let error) = result {
        XCTAssertEqual((error as? DatabaseError)?.sql, "This is not SQL")
      } else {
        XCTFail("Expected database error")
      }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }
}
