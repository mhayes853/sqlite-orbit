// Generated from GRDB 7.11.1 Tests/GRDBTests/Private/DatabaseRegionTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseRegionTests : GRDBTestCase {
    

    

    

    

    

    

    

    

    

    

    

    









    

    
    // Regression test for https://github.com/groue/GRDB.swift/issues/514
    func testIssue514() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE b (id TEXT, name TEXT);
                """)
            
            // INTEGER PRIMARY KEY
            do {
                // TODO: contact SQLite and ask if this test is expected to fail
//                let statement = try db.makeStatement(sql: "SELECT id FROM a")
//                let expectedRegion = DatabaseRegion(table: "a", columns: ["id"])
//                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT name FROM a")
                let expectedRegion = DatabaseRegion(table: "a", columns: ["name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT id, name FROM a")
                let expectedRegion = DatabaseRegion(table: "a", columns: ["id", "name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            
            // TEXT primary key
            do {
                let statement = try db.makeStatement(sql: "SELECT id FROM b")
                let expectedRegion = DatabaseRegion(table: "b", columns: ["id"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT name FROM b")
                let expectedRegion = DatabaseRegion(table: "b", columns: ["name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
            do {
                let statement = try db.makeStatement(sql: "SELECT id, name FROM b")
                let expectedRegion = DatabaseRegion(table: "b", columns: ["id", "name"])
                XCTAssertEqual(statement.databaseRegion, expectedRegion)
            }
        }
    }
}
