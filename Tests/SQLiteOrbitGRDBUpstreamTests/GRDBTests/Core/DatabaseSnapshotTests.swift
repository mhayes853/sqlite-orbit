// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseSnapshotTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest/ and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseSnapshotTests: GRDBTestCase {
    /// A helper type
    private struct Counter {
        init(dbPool: DatabasePool) throws {
            try dbPool.write { db in
                try db.execute(sql: "CREATE TABLE counter(id INTEGER PRIMARY KEY)")
            }
        }
        
        func increment(_ db: Database) throws {
            try db.execute(sql: "INSERT INTO counter DEFAULT VALUES")
        }
        
        func value(_ db: Database) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM counter")!
        }
    }
    
    // MARK: - Creation
    
    func testSnapshotCanReadBeforeDatabaseModification() throws {
        let dbPool = try makeDatabasePool()
        let snapshot = try dbPool.makeSnapshot()
        try XCTAssertEqual(snapshot.read { try $0.tableExists("foo") }, false)
    }
    
    func testSnapshotCreatedFromMainQueueCanRead() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        let snapshot = try dbPool.makeSnapshot()
        try XCTAssertEqual(snapshot.read(counter.value), 0)
    }
    
    func testSnapshotCreatedFromWriterOutsideOfTransactionCanRead() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        let snapshot = try dbPool.writeWithoutTransaction { db -> DatabaseSnapshot in
            XCTAssertFalse(db.isInsideTransaction)
            let snapshot = try dbPool.makeSnapshot()
            try counter.increment(db)
            return snapshot
        }
        try XCTAssertEqual(snapshot.read(counter.value), 0)
    }
    
    func testSnapshotCreatedFromReaderTransactionCanRead() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        let snapshot = try dbPool.read { db -> DatabaseSnapshot in
            XCTAssertTrue(db.isInsideTransaction)
            return try dbPool.makeSnapshot()
        }
        try XCTAssertEqual(snapshot.read(counter.value), 0)
    }
    
    func testSnapshotCreatedFromReaderOutsideOfTransactionCanRead() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        let snapshot = try dbPool.unsafeRead { db -> DatabaseSnapshot in
            XCTAssertFalse(db.isInsideTransaction)
            return try dbPool.makeSnapshot()
        }
        try XCTAssertEqual(snapshot.read(counter.value), 0)
    }
    

    
    // MARK: - Behavior
    
    func testSnapshotIsReadOnly() throws {
        let dbPool = try makeDatabasePool()
        let snapshot = try dbPool.makeSnapshot()
        do {
            try snapshot.read { db in
                try db.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY")
            }
            XCTFail("Expected error")
        } catch is DatabaseError { }
    }
    
    func testSnapshotIsImmutable() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        try dbPool.writeWithoutTransaction { db in
            try counter.increment(db)
            let snapshot = try dbPool.makeSnapshot()
            try counter.increment(db)
            try XCTAssertEqual(counter.value(db), 2)
            try XCTAssertEqual(snapshot.read(counter.value), 1)
            try XCTAssertEqual(dbPool.read(counter.value), 2)
            try XCTAssertEqual(snapshot.read(counter.value), 1)
            try XCTAssertEqual(counter.value(db), 2)
            try XCTAssertEqual(dbPool.read(counter.value), 2)
        }
    }
    
    // MARK: - Functions
    
    func testSnapshotInheritPoolFunctions() throws {
        dbConfiguration.prepareDatabase { db in
            let function = DatabaseFunction("foo", argumentCount: 0, pure: true) { _ in return "foo" }
            db.add(function: function)
        }
        let dbPool = try makeDatabasePool()
        
        let snapshot = try dbPool.makeSnapshot()
        try snapshot.read { db in
            try XCTAssertEqual(String.fetchOne(db, sql: "SELECT foo()")!, "foo")
        }
    }
    
    // MARK: - Collations
    
    func testSnapshotInheritPoolCollations() throws {
        dbConfiguration.prepareDatabase { db in
            let collation = DatabaseCollation("reverse") { (string1, string2) in
                return (string1 == string2) ? .orderedSame : ((string1 < string2) ? .orderedDescending : .orderedAscending)
            }
            db.add(collation: collation)
        }
        let dbPool = try makeDatabasePool()
        
        try dbPool.write { db in
            try db.execute(sql: "CREATE TABLE items (text TEXT)")
            try db.execute(sql: "INSERT INTO items (text) VALUES ('a')")
            try db.execute(sql: "INSERT INTO items (text) VALUES ('b')")
            try db.execute(sql: "INSERT INTO items (text) VALUES ('c')")
        }
        
        let snapshot = try dbPool.makeSnapshot()
        try snapshot.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT text FROM items ORDER BY text COLLATE reverse"), ["c", "b", "a"])
        }
    }
    
    // MARK: - Concurrency
    
    func testReadBlockIsolationStartingWithRead() throws {
        let dbPool = try makeDatabasePool()
        try dbPool.write { db in
            try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        
        // Block 1                      Block 2
        // dbSnapshot.read {
        // >
        let s1 = DispatchSemaphore(value: 0)
        //                              INSERT INTO items (id) VALUES (NULL)
        //                              <
        let s2 = DispatchSemaphore(value: 0)
        // SELECT COUNT(*) FROM items -> 0
        // >
        let s3 = DispatchSemaphore(value: 0)
        //                              INSERT INTO items (id) VALUES (NULL)
        //                              <
        let s4 = DispatchSemaphore(value: 0)
        // SELECT COUNT(*) FROM items -> 0
        // }
        
        let block1 = { () in
            let snapshot = try! dbPool.makeSnapshot()
            try! snapshot.read { db in
                s1.signal()
                _ = s2.wait(timeout: .distantFuture)
                // We read 0 due to snaphot isolation which was acquired before
                // `s1` could let the writer insert an item.
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items")!, 0)
                s3.signal()
                _ = s4.wait(timeout: .distantFuture)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items")!, 0)
            }
        }
        let block2 = { () in
            do {
                _ = s1.wait(timeout: .distantFuture)
                try dbPool.writeWithoutTransaction { db in
                    try db.execute(sql: "INSERT INTO items (id) VALUES (NULL)")
                    s2.signal()
                    _ = s3.wait(timeout: .distantFuture)
                    try db.execute(sql: "INSERT INTO items (id) VALUES (NULL)")
                    s4.signal()
                }
            } catch {
                XCTFail("error: \(error)")
            }
        }
        let blocks = [block1, block2]
        DispatchQueue.concurrentPerform(iterations: blocks.count) { index in
            blocks[index]()
        }
    }


    

    
    // MARK: - Checkpoints
    
    func testAutomaticCheckpointDoesNotInvalidateSnapshot() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        try dbPool.write(counter.increment)
        let snapshot = try dbPool.makeSnapshot()
        try XCTAssertEqual(snapshot.read(counter.value), 1)
        try dbPool.writeWithoutTransaction { db in
            // 1000 is enough to trigger automatic snapshot
            for _ in 0..<1000 {
                try counter.increment(db)
            }
        }
        try XCTAssertEqual(snapshot.read(counter.value), 1)
    }
    
    func testPassiveCheckpointDoesNotInvalidateSnapshot() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        try dbPool.write(counter.increment)
        let snapshot = try dbPool.makeSnapshot()
        try? dbPool.writeWithoutTransaction { _ = try $0.checkpoint(.passive) } // ignore if error or not, that's not the point
        try XCTAssertEqual(snapshot.read(counter.value), 1)
        try dbPool.write(counter.increment)
        try XCTAssertEqual(snapshot.read(counter.value), 1)
    }
    
    func testFullCheckpointDoesNotInvalidateSnapshot() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        try dbPool.write(counter.increment)
        let snapshot = try dbPool.makeSnapshot()
        try? dbPool.writeWithoutTransaction { _ = try $0.checkpoint(.full) } // ignore if error or not, that's not the point
        try XCTAssertEqual(snapshot.read(counter.value), 1)
        try dbPool.write(counter.increment)
        try XCTAssertEqual(snapshot.read(counter.value), 1)
    }
    
    func testRestartCheckpointDoesNotInvalidateSnapshot() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        try dbPool.write(counter.increment)
        let snapshot = try dbPool.makeSnapshot()
        try? dbPool.writeWithoutTransaction { _ = try $0.checkpoint(.restart) } // ignore if error or not, that's not the point
        try XCTAssertEqual(snapshot.read(counter.value), 1)
        try dbPool.write(counter.increment)
        try XCTAssertEqual(snapshot.read(counter.value), 1)
    }
    
    func testTruncateCheckpointDoesNotInvalidateSnapshot() throws {
        let dbPool = try makeDatabasePool()
        let counter = try Counter(dbPool: dbPool)
        try dbPool.write(counter.increment)
        let snapshot = try dbPool.makeSnapshot()
        try? dbPool.writeWithoutTransaction { _ = try $0.checkpoint(.truncate) } // ignore if error or not, that's not the point
        try XCTAssertEqual(snapshot.read(counter.value), 1)
        try dbPool.write(counter.increment)
        try XCTAssertEqual(snapshot.read(counter.value), 1)
    }
    
    // MARK: - Schema Cache
    

    
    // MARK: - Closing
    
    func testClose() throws {
        let snapshot = try makeDatabasePool().makeSnapshot()
        try snapshot.close()
        
        // After close, access throws SQLITE_MISUSE
        do {
            try snapshot.read { db in
                try db.execute(sql: "SELECT * FROM sqlite_master")
            }
            XCTFail("Expected Error")
        } catch DatabaseError.SQLITE_MISUSE { }
        
        // After close, closing is a noop
        try snapshot.close()
    }
    
    func testCloseAfterUse() throws {
        let snapshot = try makeDatabasePool().makeSnapshot()
        try snapshot.read { db in
            try db.execute(sql: "SELECT * FROM sqlite_master")
        }
        try snapshot.close()
        
        // After close, access throws SQLITE_MISUSE
        do {
            try snapshot.read { db in
                try db.execute(sql: "SELECT * FROM sqlite_master")
            }
            XCTFail("Expected Error")
        } catch DatabaseError.SQLITE_MISUSE { }
        
        // After close, closing is a noop
        try snapshot.close()
    }
    
    func testCloseWithCachedStatement() throws {
        let snapshot = try makeDatabasePool().makeSnapshot()
        try snapshot.read { db in
            _ = try db.cachedStatement(sql: "SELECT * FROM sqlite_master")
        }
        try snapshot.close()
        
        // After close, access throws SQLITE_MISUSE
        do {
            try snapshot.read { db in
                try db.execute(sql: "SELECT * FROM sqlite_master")
            }
            XCTFail("Expected Error")
        } catch DatabaseError.SQLITE_MISUSE { }
        
        // After close, closing is a noop
        try snapshot.close()
    }
    

}
