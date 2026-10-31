// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseWriterTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

@TaskLocal private var localUUID = UUID()

class DatabaseWriterTests : GRDBTestCase {
    

    

    
    func testAsyncWriteWithoutTransactionSuccess() throws {
        func test(_ dbWriter: some DatabaseWriter) throws {
            let expectation = self.expectation(description: "updates")
            let semaphore = DispatchSemaphore(value: 0)
            dbWriter.asyncWriteWithoutTransaction { db in
                // Make sure this block executes asynchronously
                semaphore.wait()
                do {
                    try db.execute(sql: "CREATE TABLE testAsyncWriteWithoutTransaction (a)")
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
                expectation.fulfill()
            }
            semaphore.signal()

            waitForExpectations(timeout: 2, handler: nil)
            let tableExists = try dbWriter.read { try $0.tableExists("testAsyncWriteWithoutTransaction") }
            XCTAssertTrue(tableExists)
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testAsyncWriteWithoutTransactionError() throws {
        func test(_ dbWriter: some DatabaseWriter) throws {
            let expectation = self.expectation(description: "updates")
            let semaphore = DispatchSemaphore(value: 0)
            dbWriter.asyncWriteWithoutTransaction { db in
                // Make sure this block executes asynchronously
                semaphore.wait()
                do {
                    try db.execute(sql: "This is not SQL")
                    XCTFail("Expected error")
                } catch let error as DatabaseError {
                    XCTAssertEqual(error.sql, "This is not SQL")
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
                expectation.fulfill()
            }
            semaphore.signal()
            waitForExpectations(timeout: 2, handler: nil)
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testAsyncWriteSuccess() throws {
        func test(_ dbWriter: some DatabaseWriter) throws {
            let expectation = self.expectation(description: "updates")
            let semaphore = DispatchSemaphore(value: 0)
            dbWriter.asyncWrite({ db in
                // Make sure this block executes asynchronously
                semaphore.wait()
                try db.execute(sql: "CREATE TABLE testAsyncWrite (a)")
            }, completion: { db, result in
                XCTAssertFalse(db.isInsideTransaction)
                switch result {
                case .success:
                    break
                case let .failure(error):
                    XCTFail("Unexpected error: \(error)")
                }
                expectation.fulfill()
            })
            semaphore.signal()
            
            waitForExpectations(timeout: 2, handler: nil)
            let tableExists = try dbWriter.read { try $0.tableExists("testAsyncWrite") }
            XCTAssertTrue(tableExists)
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testAsyncWriteError() throws {
        func test(_ dbWriter: some DatabaseWriter) throws {
            let expectation = self.expectation(description: "updates")
            let semaphore = DispatchSemaphore(value: 0)
            dbWriter.asyncWrite({ db in
                // Make sure this block executes asynchronously
                semaphore.wait()
                try db.execute(sql: "This is not SQL")
            }, completion: { db, result in
                XCTAssertFalse(db.isInsideTransaction)
                switch result {
                case .success:
                    XCTFail("Expected error")
                case let .failure(error):
                    if let error = error as? DatabaseError {
                        XCTAssertEqual(error.sql, "This is not SQL")
                    } else {
                        XCTFail("Unexpected error: \(error)")
                    }
                }
                expectation.fulfill()
            })
            semaphore.signal()
            waitForExpectations(timeout: 2, handler: nil)
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testAnyDatabaseWriter() throws {
        // This test passes if this code compiles.
        let dbQueue = try DatabaseQueue()
        let _: any DatabaseWriter = AnyDatabaseWriter(dbQueue)
    }
    





    
    // See https://github.com/groue/GRDB.swift/issues/424
    func testIssue424() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE t(a);
                INSERT INTO t VALUES (1)
                """)
        }
        try dbQueue.read { db in
            _ = try Row.fetchCursor(db.cachedStatement(sql: "SELECT * FROM t")).next()
        }
        try dbQueue.erase()
    }
    

    
    func testAsyncAwait_write() async throws {
        func setup<T: DatabaseWriter>(_ dbWriter: T) throws -> T {
            try dbWriter.write { db in
                try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY)")
            }
            return dbWriter
        }
        func test<T: DatabaseWriter>(_ dbWriter: T) async throws {
            let count = try await dbWriter.write { db -> Int in
                try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t")!
            }
            XCTAssertEqual(count, 1)
        }
        
        try await test(setup(makeDatabaseQueue()))
        try await test(setup(makeDatabasePool()))
    }
    

    

    
    func testAsyncAwait_erase() async throws {
        func setup<T: DatabaseWriter>(_ dbWriter: T) throws -> T {
            try dbWriter.write { db in
                try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY)")
            }
            return dbWriter
        }
        func test<T: DatabaseWriter>(_ dbWriter: T) async throws {
            try await dbWriter.erase()
            let tableExists = try await dbWriter.read { try $0.tableExists("t") }
            XCTAssertFalse(tableExists)
        }
        
        try await test(setup(makeDatabaseQueue()))
        try await test(setup(makeDatabasePool()))
    }
    

    

    
    /// A test related to <https://github.com/groue/GRDB.swift/issues/1456>
    func testAsyncWriteThenRead() async throws {
        /// An async read performed after an async write should see the write.
        func test(_ dbWriter: some DatabaseWriter) async throws {
            try await dbWriter.write { db in
                try db.execute(sql: """
                    CREATE TABLE t (id INTEGER PRIMARY KEY);
                    INSERT INTO t VALUES (1);
                    """)
            }
            
            let count = try await dbWriter.read { db in
                try Table("t").fetchCount(db)
            }
            
            XCTAssertEqual(count, 1)
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
    }
    
    // MARK: - Task locals
    
    func test_write_can_access_task_local() async throws {
        func test<T: DatabaseWriter>(_ dbWriter: T) async throws {
            let expectedUUID = UUID()
            let dbUUID = try await $localUUID.withValue(expectedUUID) {
                try await dbWriter.write { db in localUUID }
            }
            XCTAssertEqual(dbUUID, expectedUUID)
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
    }
    
    func test_writeWithoutTransaction_can_access_task_local() async throws {
        func test<T: DatabaseWriter>(_ dbWriter: T) async throws {
            let expectedUUID = UUID()
            let dbUUID = try await $localUUID.withValue(expectedUUID) {
                try await dbWriter.writeWithoutTransaction { db in localUUID }
            }
            XCTAssertEqual(dbUUID, expectedUUID)
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
    }
    


    
    // MARK: - Task Cancellation
    
    // Regression test for <https://github.com/groue/GRDB.swift/issues/1715>.
    func test_write_is_possible_after_read_cancelled_after_database_access() async throws {
        // When a read access is cancelled, DatabaseQueue needs to execute
        // `PRAGMA query_only=0` in order to restore the read/write access.
        //
        // Here we test that this pragma can run from a cancelled read.
        //
        // Small difficulty: some SQLite versions (seen with 3.43.2) execute
        // the `query_only` pragma at compile time, not only at execution
        // time (yeah, that's an SQLite bug). The problem of this bug is
        // that even if the `PRAGMA query_only=0` is not executed due to
        // Task cancellation, its side effect is still executed when it is
        // compiled, unintentionally. A cancelled `PRAGMA query_only=0`
        // still works!
        //
        // To avoid this SQLite bug from messing with our test, we perform
        // two reads: one that compiles and cache `PRAGMA query_only`
        // statements, and a second read that we cancel. This time the
        // `PRAGMA query_only=0` triggers its side effect if and only if it
        // is actually executed (the behavior we are testing).
        func test(_ dbWriter: some DatabaseWriter) async throws {
            let semaphore = AsyncSemaphore(value: 0)
            let cancelledTaskMutex = Mutex<Task<Void, any Error>?>(nil)
            let task = Task {
                await semaphore.wait()
                
                // First read, not cancelled, so that all `query_only`
                // pragma statements are compiled (see above).
                try await dbWriter.read { db in }
                
                // Second read, cancelled.
                try await dbWriter.read { db in
                    try XCTUnwrap(cancelledTaskMutex.load()).cancel()
                }
            }
            cancelledTaskMutex.store(task)
            semaphore.signal()
            // Wait until reads are completed
            try? await task.value
            
            // Write access is restored after read cancellation (no error is thrown)
            try await dbWriter.write { db in
                try db.execute(sql: "CREATE TABLE test(a)")
            }
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
        try await test(AnyDatabaseWriter(makeDatabaseQueue()))
    }
    
    func test_writeWithoutTransaction_is_cancelled_by_Task_cancellation_performed_before_database_access() async throws {
        func test(_ dbWriter: some DatabaseWriter) async throws {
            let semaphore = AsyncSemaphore(value: 0)
            let task = Task {
                await semaphore.wait()
                try await dbWriter.writeWithoutTransaction { db in
                    XCTFail("Should not be executed")
                }
            }
            task.cancel()
            semaphore.signal()
            
            do {
                try await task.value
                XCTFail("Expected error")
            } catch {
                XCTAssert(error is CancellationError)
            }
            
            // Database access is restored after cancellation (no error is thrown)
            try await dbWriter.writeWithoutTransaction { db in
                try db.execute(sql: "SELECT 0")
            }
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
        try await test(AnyDatabaseWriter(makeDatabaseQueue()))
    }
    
    func test_successful_writeWithoutTransaction_is_not_cancelled_by_Task_cancellation_performed_after_database_access() async throws {
        func test(_ dbWriter: some DatabaseWriter) async throws {
            let semaphore = AsyncSemaphore(value: 0)
            let cancelledTaskMutex = Mutex<Task<Void, any Error>?>(nil)
            let task = Task {
                await semaphore.wait()
                try await dbWriter.writeWithoutTransaction { db in
                    try XCTUnwrap(cancelledTaskMutex.load()).cancel()
                    XCTAssertTrue(Task.isCancelled)
                }
            }
            cancelledTaskMutex.store(task)
            semaphore.signal()
            
            // Task has completed without any error
            try await task.value
            
            // Database access is restored after cancellation (no error is thrown)
            try await dbWriter.writeWithoutTransaction { db in
                try db.execute(sql: "SELECT 0")
            }
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
        try await test(AnyDatabaseWriter(makeDatabaseQueue()))
    }
    
    func test_statement_execution_from_writeWithoutTransaction_is_cancelled_by_Task_cancellation_performed_after_database_access() async throws {
        func test(_ dbWriter: some DatabaseWriter) async throws {
            let semaphore = AsyncSemaphore(value: 0)
            let cancelledTaskMutex = Mutex<Task<Void, any Error>?>(nil)
            let task = Task {
                await semaphore.wait()
                try await dbWriter.writeWithoutTransaction { db in
                    try XCTUnwrap(cancelledTaskMutex.load()).cancel()
                    try db.execute(sql: "SELECT 0")
                    XCTFail("Expected error")
                }
            }
            cancelledTaskMutex.store(task)
            semaphore.signal()
            
            do {
                try await task.value
                XCTFail("Expected error")
            } catch {
                XCTAssert(error is CancellationError)
            }
            
            // Database access is restored after cancellation (no error is thrown)
            try await dbWriter.writeWithoutTransaction { db in
                try db.execute(sql: "SELECT 0")
            }
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
        try await test(AnyDatabaseWriter(makeDatabaseQueue()))
    }
    
    func test_cursor_iteration_from_writeWithoutTransaction_is_interrupted_by_Task_cancellation_performed_after_database_access() async throws {
        func test(_ dbWriter: some DatabaseWriter) async throws {
            let semaphore = AsyncSemaphore(value: 0)
            let cancelledTaskMutex = Mutex<Task<Void, any Error>?>(nil)
            let task = Task {
                await semaphore.wait()
                try await dbWriter.writeWithoutTransaction { db in
                    let cursor = try Int.fetchCursor(db, sql: """
                        SELECT 1 UNION ALL SELECT 2
                        """)
                    _ = try cursor.next()
                    try XCTUnwrap(cancelledTaskMutex.load()).cancel()
                    _ = try cursor.next()
                    XCTFail("Expected error")
                }
            }
            cancelledTaskMutex.store(task)
            semaphore.signal()
            
            do {
                try await task.value
                XCTFail("Expected error")
            } catch {
                XCTAssert(error is CancellationError)
            }
            
            // Database access is restored after cancellation (no error is thrown)
            try await dbWriter.writeWithoutTransaction { db in
                try db.execute(sql: "SELECT 0")
            }
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
        try await test(AnyDatabaseWriter(makeDatabaseQueue()))
    }
    
    func test_write_is_cancelled_by_Task_cancellation_performed_before_database_access() async throws {
        func test(_ dbWriter: some DatabaseWriter) async throws {
            let semaphore = AsyncSemaphore(value: 0)
            let task = Task {
                await semaphore.wait()
                try await dbWriter.write { db in
                    XCTFail("Should not be executed")
                }
            }
            task.cancel()
            semaphore.signal()
            
            do {
                try await task.value
                XCTFail("Expected error")
            } catch {
                XCTAssert(error is CancellationError)
            }
            
            // Database access is restored after cancellation (no error is thrown)
            try await dbWriter.write { db in
                try db.execute(sql: "SELECT 0")
            }
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
        try await test(AnyDatabaseWriter(makeDatabaseQueue()))
    }
    
    func test_write_is_cancelled_by_Task_cancellation_performed_after_database_access() async throws {
        func test(_ dbWriter: some DatabaseWriter) async throws {
            let semaphore = AsyncSemaphore(value: 0)
            let cancelledTaskMutex = Mutex<Task<Void, any Error>?>(nil)
            let task = Task {
                await semaphore.wait()
                try await dbWriter.write { db in
                    try XCTUnwrap(cancelledTaskMutex.load()).cancel()
                }
            }
            cancelledTaskMutex.store(task)
            semaphore.signal()
            
            do {
                try await task.value
                XCTFail("Expected error")
            } catch {
                XCTAssert(error is CancellationError)
            }
            
            // Database access is restored after cancellation (no error is thrown)
            try await dbWriter.write { db in
                try db.execute(sql: "SELECT 0")
            }
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
        try await test(AnyDatabaseWriter(makeDatabaseQueue()))
    }
    
    func test_statement_execution_from_write_is_cancelled_by_Task_cancellation_performed_after_database_access() async throws {
        func test(_ dbWriter: some DatabaseWriter) async throws {
            let semaphore = AsyncSemaphore(value: 0)
            let cancelledTaskMutex = Mutex<Task<Void, any Error>?>(nil)
            let task = Task {
                await semaphore.wait()
                try await dbWriter.write { db in
                    try XCTUnwrap(cancelledTaskMutex.load()).cancel()
                    try db.execute(sql: "SELECT 0")
                    XCTFail("Expected error")
                }
            }
            cancelledTaskMutex.store(task)
            semaphore.signal()
            
            do {
                try await task.value
                XCTFail("Expected error")
            } catch {
                XCTAssert(error is CancellationError)
            }
            
            // Database access is restored after cancellation (no error is thrown)
            try await dbWriter.write { db in
                try db.execute(sql: "SELECT 0")
            }
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
        try await test(AnyDatabaseWriter(makeDatabaseQueue()))
    }
    
    func test_cursor_iteration_from_write_is_interrupted_by_Task_cancellation_performed_after_database_access() async throws {
        func test(_ dbWriter: some DatabaseWriter) async throws {
            let semaphore = AsyncSemaphore(value: 0)
            let cancelledTaskMutex = Mutex<Task<Void, any Error>?>(nil)
            let task = Task {
                await semaphore.wait()
                try await dbWriter.write { db in
                    let cursor = try Int.fetchCursor(db, sql: """
                        SELECT 1 UNION ALL SELECT 2
                        """)
                    _ = try cursor.next()
                    try XCTUnwrap(cancelledTaskMutex.load()).cancel()
                    _ = try cursor.next()
                    XCTFail("Expected error")
                }
            }
            cancelledTaskMutex.store(task)
            semaphore.signal()
            
            do {
                try await task.value
                XCTFail("Expected error")
            } catch {
                XCTAssert(error is CancellationError)
            }
            
            // Database access is restored after cancellation (no error is thrown)
            try await dbWriter.write { db in
                try db.execute(sql: "SELECT 0")
            }
        }
        
        try await test(makeDatabaseQueue())
        try await test(makeDatabasePool())
        try await test(AnyDatabaseWriter(makeDatabaseQueue()))
    }
    

    

    

    

    

}
