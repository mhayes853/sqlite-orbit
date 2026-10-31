// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabasePool/DatabasePoolFunctionTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest/ and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabasePoolFunctionTests: GRDBTestCase {
    
    func testFunctionIsSharedBetweenWriterAndReaders() throws {
        dbConfiguration.prepareDatabase { db in
            db.add(function: DatabaseFunction("function1", argumentCount: 1, pure: true) { (dbValues: [DatabaseValue]) in
                return dbValues[0]
            })
            
        }
        let dbPool = try makeDatabasePool()
        
        try dbPool.write { db in
            try db.execute(sql: "CREATE TABLE items (text TEXT)")
            try db.execute(sql: "INSERT INTO items (text) VALUES (function1('a'))")
        }
        try dbPool.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT function1(text) FROM items")!, "a")
        }
    }
}
