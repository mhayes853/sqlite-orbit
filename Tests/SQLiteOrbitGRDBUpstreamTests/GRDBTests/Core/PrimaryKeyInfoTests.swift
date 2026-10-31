// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/PrimaryKeyInfoTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class PrimaryKeyInfoTests: GRDBTestCase {
    
    func testMissingTable() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            do {
                _ = try db.primaryKey("items")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message, "no such table: items")
                XCTAssertEqual(error.description, "SQLite error 1: no such table: items")
            }
        }
    }
    
    func testView() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE VIEW items AS SELECT 1")
            do {
                _ = try db.primaryKey("items")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message, """
                    database view items has no primary key
                    """)
                XCTAssertEqual(error.description, """
                    SQLite error 1: database view items has no primary key
                    """)
            }
        }
    }
    

    

    

    

    

    

    

    
    func testUnknownSchema() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE items (name TEXT)")
            do {
                _ = try db.primaryKey("items", in: "invalid")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message, "no such schema: invalid")
                XCTAssertEqual(error.description, "SQLite error 1: no such schema: invalid")
            }
        }
    }
    

    

    

    

    
    // MARK: - Customization with DatabaseSchemaSource
    

    

    

}
