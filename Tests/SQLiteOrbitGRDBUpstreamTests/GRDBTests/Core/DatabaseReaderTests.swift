// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseReaderTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest/ and run `sync`.
import XCTest
import SQLiteOrbitGRDB

@TaskLocal private var localUUID = UUID()

class DatabaseReaderTests : GRDBTestCase {
    func testAnyDatabaseReader() throws {
        // This test passes if this code compiles.
        let dbQueue = try DatabaseQueue()
        let _: any DatabaseReader = AnyDatabaseReader(dbQueue)
    }
    
    // Test passes if it compiles.
    func testInitFromGeneric(_ reader: some DatabaseReader) {
        _ = AnyDatabaseReader(reader)
    }
    
    // Test passes if it compiles.
    // See <https://github.com/groue/GRDB.swift/issues/1541>
    func testInitFromExistentialReader(_ reader: any DatabaseReader) {
        _ = AnyDatabaseReader(reader)
    }
    
    // Test passes if it compiles.
    // See <https://github.com/groue/GRDB.swift/issues/1541>
    func testInitFromExistentialWriter(_ writer: any DatabaseWriter) {
        _ = AnyDatabaseReader(writer)
    }
    
    // MARK: - Read
    

    

    

    

    
    // MARK: - UnsafeRead
    

    

    
    // MARK: - UnsafeReentrantRead
    

    

    
    func testUnsafeReentrantReadIsReentrantFromWrite() throws {
        func test(_ dbWriter: some DatabaseWriter) throws {
            try dbWriter.write { db1 in
                try dbWriter.unsafeReentrantRead { db2 in
                    try dbWriter.unsafeReentrantRead { db3 in
                        XCTAssertTrue(db1 === db2)
                        XCTAssertTrue(db2 === db3)
                    }
                }
            }
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    // MARK: - AsyncRead
    

    

    
    // MARK: - Function
    

    
    // MARK: - Collation
    

    
    // MARK: - Backup
    

    
    // MARK: - Task locals
    

    

    
    // MARK: - Task Cancellation
    

    



    

    

    



    

    

}
