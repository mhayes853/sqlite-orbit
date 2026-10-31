// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseAbortedTransactionTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseAbortedTransactionTests : GRDBTestCase {
    

    

    

    

    

    
    func testTransactionAbortedByConflictPreventsFurtherDatabaseAccess() throws {
        func setup<T: DatabaseWriter>(_ dbWriter: T) throws -> T {
            try dbWriter.write { db in
                try db.execute(sql: """
                    CREATE TABLE t(a UNIQUE ON CONFLICT ROLLBACK);
                    """)
            }
            return dbWriter
        }
        func test(_ dbWriter: some DatabaseWriter) throws {
            do {
                try dbWriter.write { db in
                    do {
                        try db.execute(sql: """
                            INSERT INTO t (a) VALUES (1);
                            INSERT INTO t (a) VALUES (1);
                            """)
                        XCTFail("Expected error")
                    } catch let error as DatabaseError {
                        XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
                        XCTAssertEqual(error.message, "UNIQUE constraint failed: t.a")
                        XCTAssertEqual(error.sql, "INSERT INTO t (a) VALUES (1)")
                    } catch {
                        XCTFail("Unexpected error: \(error)")
                    }
                    
                    XCTAssertFalse(db.isInsideTransaction)
                    
                    try db.execute(sql: "INSERT INTO t (a) VALUES (2)")
                }
                XCTFail("Expected error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ABORT)
                XCTAssertEqual(error.message, "Transaction was aborted")
                XCTAssertEqual(error.sql, "INSERT INTO t (a) VALUES (2)")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        
        try test(setup(DatabaseQueue()))
        try test(setup(makeDatabaseQueue()))
        try test(setup(makeDatabasePool()))
    }
    
    func testTransactionAbortedByUser() throws {
        func setup<T: DatabaseWriter>(_ dbWriter: T) throws -> T {
            try dbWriter.write { db in
                try db.execute(sql: "CREATE TABLE t(a);")
            }
            return dbWriter
        }
        func test(_ dbReader: some DatabaseReader) throws {
            do {
                try dbReader.unsafeRead { db in
                    try db.inTransaction {
                        try db.execute(sql: """
                            SELECT * FROM t;
                            ROLLBACK;
                            SELECT * FROM t;
                            """)
                        return .commit
                    }
                }
                XCTFail("Expected error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ABORT)
                XCTAssertEqual(error.message, "Transaction was aborted")
                XCTAssertEqual(error.sql, "SELECT * FROM t")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        
        try test(setup(DatabaseQueue()))
        try test(setup(makeDatabaseQueue()))
        try test(setup(makeDatabasePool()))
    }
    

}
