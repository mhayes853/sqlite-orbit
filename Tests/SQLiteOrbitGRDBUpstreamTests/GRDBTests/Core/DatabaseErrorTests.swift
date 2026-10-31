// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseErrorTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseErrorTests: GRDBTestCase {
    
    func testDatabaseErrorMessage() {
        // We don't test for actual messages, since they may depend on SQLite version
        XCTAssertEqual(DatabaseError().resultCode, .SQLITE_ERROR)
        XCTAssertNotNil(DatabaseError().message)
        XCTAssertNotNil(DatabaseError(resultCode: .SQLITE_BUSY).message)
        XCTAssertNotEqual(DatabaseError().message, DatabaseError(resultCode: .SQLITE_BUSY).message)
    }
    











    
    func testNSErrorBridging() throws {
#if !canImport(Darwin)
        throw XCTSkip("NSError bridging not available on non-Darwin platforms")
#else
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "parents") { $0.column("id", .integer).primaryKey() }
            try db.create(table: "children") { $0.belongsTo("parent") }
            do {
                try db.execute(sql: "INSERT INTO children (parentId) VALUES (1)")
            } catch let error as NSError {
                XCTAssertEqual(DatabaseError.errorDomain, "GRDB.DatabaseError")
                XCTAssertEqual(error.domain, DatabaseError.errorDomain)
                XCTAssertEqual(error.code, 787)
                XCTAssertNotNil(error.localizedFailureReason)
            }
        }
#endif
    }
}
