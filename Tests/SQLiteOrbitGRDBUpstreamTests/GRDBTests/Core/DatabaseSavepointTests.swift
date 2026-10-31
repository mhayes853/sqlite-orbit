// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseSavepointTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

func insertItem(_ db: Database, name: String) throws {
    try db.execute(sql: "INSERT INTO items (name) VALUES (?)", arguments: [name])
}

func fetchAllItemNames(_ dbReader: some DatabaseReader) throws -> [String] {
    try dbReader.read { db in
        try String.fetchAll(db, sql: "SELECT * FROM items ORDER BY name")
    }
}



class DatabaseSavepointTests: GRDBTestCase {
    
    override func setup(_ dbWriter: some DatabaseWriter) throws {
        try dbWriter.write { db in
            try db.execute(sql: "CREATE TABLE items (name TEXT)")
        }
    }
    
    func testIsInsideTransaction() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            XCTAssertFalse(db.isInsideTransaction)
            try db.inTransaction {
                XCTAssertTrue(db.isInsideTransaction)
                return .commit
            }
            XCTAssertFalse(db.isInsideTransaction)
            
            try db.execute(sql: "BEGIN DEFERRED TRANSACTION")
            XCTAssertTrue(db.isInsideTransaction)
            try db.execute(sql: "COMMIT")    // does not trigger sqlite3_commit_hook, because transaction was not open yet.
            XCTAssertFalse(db.isInsideTransaction)
            
            try db.execute(sql: "BEGIN DEFERRED TRANSACTION")
            XCTAssertTrue(db.isInsideTransaction)
            try db.execute(sql: "ROLLBACK")  // does trigger sqlite3_rollback_hook
            XCTAssertFalse(db.isInsideTransaction)
            
            try db.execute(sql: "BEGIN IMMEDIATE TRANSACTION")
            XCTAssertTrue(db.isInsideTransaction)
            try db.execute(sql: "COMMIT")    // does trigger sqlite3_commit_hook
            XCTAssertFalse(db.isInsideTransaction)
            
            try db.execute(sql: "BEGIN IMMEDIATE TRANSACTION")
            XCTAssertTrue(db.isInsideTransaction)
            try db.execute(sql: "ROLLBACK")
            XCTAssertFalse(db.isInsideTransaction)
        }
    }

    func testIsInsideTransactionWithImplicitRollback() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.create(table: "test") { t in
                t.column("value", .integer).unique()
            }
            try db.execute(sql: "BEGIN TRANSACTION")
            XCTAssertTrue(db.isInsideTransaction)
            try db.execute(sql: "INSERT INTO test (value) VALUES (?)", arguments: [1])
            XCTAssertTrue(db.isInsideTransaction)
            XCTAssertThrowsError(try db.execute(sql: "INSERT OR ROLLBACK INTO test (value) VALUES (?)", arguments: [1]))
            XCTAssertFalse(db.isInsideTransaction)
            XCTAssertThrowsError(try db.execute(sql: "COMMIT"))
        }
    }
    









}
