// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/FetchRequestTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class FetchRequestTests: GRDBTestCase {
    func testRequestFetchCount() throws {
        let request: SQLRequest<Int> = "SELECT * FROM table1"
        
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "table1") { t in
                t.primaryKey("id", .integer)
            }
            try db.execute(sql: "INSERT INTO table1 DEFAULT VALUES")
            try db.execute(sql: "INSERT INTO table1 DEFAULT VALUES")
            
            let count = try request.fetchCount(db)
            XCTAssertEqual(lastSQLQuery, "SELECT COUNT(*) FROM (SELECT * FROM table1)")
            XCTAssertEqual(count, 2)
        }
    }
    

    

    

}
