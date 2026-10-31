// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseLogErrorTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseLogErrorTests: GRDBTestCase {
    
    func testErrorLog() throws {
        // TODO: restore flaky test
        throw XCTSkip("Flaky")
        
//        // TODO: understand why this test fails on iOS 13 with system SQLite
//        #if GRDBCUSTOMSQLITE || SQLITE_HAS_CODEC
//        let dbQueue = try makeDatabaseQueue()
//        dbQueue.inDatabase { db in
//            _ = try? db.execute(sql: "Abracadabra")
//        }
//        XCTAssertEqual(lastResultCode!, ResultCode.SQLITE_ERROR)
//        // Don't check for exact error message because it depends on SQLite version
//        XCTAssert(lastMessage!.contains("syntax error"))
//        XCTAssert(lastMessage!.contains("Abracadabra"))
//        #endif
    }
}
