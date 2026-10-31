// Generated from GRDB 7.11.1 Tests/GRDBTests/ValueObservation/ValueObservationTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import Dispatch
import SQLiteOrbitGRDB

class ValueObservationTests: GRDBTestCase {

    

    

    

    

    

    

    
    // MARK: - Constant Explicit Region
    

    
    // MARK: - Snapshot Optimization
    
    func testDisallowedSnapshotOptimizationWithAsyncScheduler() throws {
        let dbPool = try makeDatabasePool()
        try dbPool.write { db in
            try db.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)")
        }
        
        // Force DatabasePool to perform two initial fetches, because between
        // its first read access, and its write access that installs the
        // transaction observer, some write did happen.
        let needsChangeMutex = Mutex(true)
        let observation = ValueObservation.trackingConstantRegion { db -> Int in
            let needsChange = needsChangeMutex.withLock { needed in
                let wasNeeded = needed
                needed = false
                return wasNeeded
            }
            if needsChange {
                try dbPool.write { db in
                    try db.execute(sql: """
                    INSERT INTO t DEFAULT VALUES;
                    DELETE FROM t;
                    """)
                }
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t")!
        }
        
        let expectation = self.expectation(description: "")
        expectation.expectedFulfillmentCount = 2
        let observedCountsMutex: Mutex<[Int]> = Mutex([])
        let cancellable = observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: { error in XCTFail("Unexpected error: \(error)") },
            onChange: { count in
                observedCountsMutex.withLock { $0.append(count) }
                expectation.fulfill()
            })
        withExtendedLifetime(cancellable) {
            waitForExpectations(timeout: 2, handler: nil)
            XCTAssertEqual(observedCountsMutex.load(), [0, 0])
        }
    }
    

    
    func testAllowedSnapshotOptimizationWithAsyncScheduler() throws {
        let dbPool = try makeDatabasePool()
        try dbPool.write { db in
            try db.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)")
        }
        
        // Allow pool to perform a single initial fetch, because between
        // its first read access, and its write access that installs the
        // transaction observer, no write did happen.
        let needsChangeMutex = Mutex(true)
        let observation = ValueObservation.trackingConstantRegion { db -> Int in
            let needsChange = needsChangeMutex.withLock { needed in
                let wasNeeded = needed
                needed = false
                return wasNeeded
            }
            if needsChange {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    try! dbPool.write { db in
                        try db.execute(sql: """
                            INSERT INTO t DEFAULT VALUES;
                            """)
                    }
                }
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t")!
        }
        
        let expectedCounts: [Int]
#if SQLITE_ENABLE_SNAPSHOT && !SQLITE_DISABLE_SNAPSHOT
        // Optimization available
        expectedCounts = [0, 1]
#else
        // Optimization not available
        expectedCounts = [0, 0, 1]
#endif
        
        let expectation = self.expectation(description: "")
        expectation.expectedFulfillmentCount = expectedCounts.count
        let observedCountsMutex: Mutex<[Int]> = Mutex([])
        let cancellable = observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: { error in XCTFail("Unexpected error: \(error)") },
            onChange: { count in
                observedCountsMutex.withLock { $0.append(count) }
                expectation.fulfill()
            })
        withExtendedLifetime(cancellable) {
            waitForExpectations(timeout: 2, handler: nil)
            XCTAssertEqual(observedCountsMutex.load(), expectedCounts)
        }
    }
    

    
    // MARK: - Snapshot Observation
    
#if SQLITE_ENABLE_SNAPSHOT && !SQLITE_DISABLE_SNAPSHOT
    func testDatabaseSnapshotPoolObservation() throws {
        let dbPool = try makeDatabasePool()
        try dbPool.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
        
        let expectation = XCTestExpectation()
        expectation.assertForOverFulfill = false
        
        let observation = ValueObservation.trackingConstantRegion { db in
            try db.registerAccess(to: Table("t"))
            expectation.fulfill()
            return try DatabaseSnapshotPool(db)
        }
        
        let recorder = observation.record(in: dbPool)
        wait(for: [expectation], timeout: 5)
        try dbPool.write { try $0.execute(sql: "INSERT INTO t DEFAULT VALUES") }
        
        let results = try wait(for: recorder.next(2), timeout: 5)
        XCTAssertEqual(results.count, 2)
        try XCTAssertEqual(results[0].read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t")! }, 0)
        try XCTAssertEqual(results[1].read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t")! }, 1)
    }
#endif
    
    // MARK: - Unspecified Changes
    

    
    // MARK: - Cancellation
    

    

    

    

    

    

    
    // MARK: - Main Actor
    @MainActor func test_mainActor_observation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "test") { t in
                t.autoIncrementedPrimaryKey("id")
            }
        }
        
        let observation = ValueObservation.tracking {
            try Table("test").fetchCount($0)
        }
        
        var value = 0 // No mutex necessary!
        let expectation = self.expectation(description: "completion")
        let cancellable = observation.start(
            in: dbQueue,
            onError: { error in XCTFail("Unexpected error: \(error)") },
            onChange: {
                value = $0
                if value == 2 {
                    expectation.fulfill()
                }
            })

        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO test DEFAULT VALUES")
            try db.execute(sql: "INSERT INTO test DEFAULT VALUES")
        }
        withExtendedLifetime(cancellable) { _ in
            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Async Await
#if canImport(Combine)
    
    func testAsyncAwait_values_prefix() async throws {
        func test(_ writer: some DatabaseWriter) async throws {
            // We need something to change
            try await writer.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            let cancellationExpectation = expectation(description: "cancelled")
            let task = Task { () -> [Int] in
                var counts: [Int] = []
                let observation = ValueObservation
                    .trackingConstantRegion(Table("t").fetchCount)
                    .handleEvents(didCancel: { cancellationExpectation.fulfill() })
                
                for try await count in try observation.values(in: writer).prefix(while: { $0 <= 3 }) {
                    counts.append(count)
                    try await writer.write { try $0.execute(sql: "INSERT INTO t DEFAULT VALUES") }
                }
                return counts
            }
            
            let counts = try await task.value
            XCTAssertTrue(counts.contains(0))
            XCTAssertTrue(counts.contains(where: { $0 >= 2 }))
            XCTAssertEqual(counts.sorted(), counts)
            
            // Observation was ended
            await fulfillment(of: [cancellationExpectation], timeout: 2)
        }
        
        try await AsyncTest(test).run { try DatabaseQueue() }
        try await AsyncTest(test).runAtTemporaryDatabasePath { try DatabaseQueue(path: $0) }
        try await AsyncTest(test).runAtTemporaryDatabasePath { try DatabasePool(path: $0) }
    }
    
    func testAsyncAwait_values_break() async throws {
        func test(_ writer: some DatabaseWriter) async throws {
            // We need something to change
            try await writer.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            let cancellationExpectation = expectation(description: "cancelled")
            let task = Task { () -> [Int] in
                var counts: [Int] = []
                let observation = ValueObservation
                    .trackingConstantRegion(Table("t").fetchCount)
                    .handleEvents(didCancel: { cancellationExpectation.fulfill() })
                
                for try await count in observation.values(in: writer) {
                    counts.append(count)
                    if count > 3 {
                        break
                    } else {
                        try await writer.write { try $0.execute(sql: "INSERT INTO t DEFAULT VALUES") }
                    }
                }
                return counts
            }
            
            let counts = try await task.value
            XCTAssertTrue(counts.contains(0))
            XCTAssertTrue(counts.contains(where: { $0 >= 2 }))
            XCTAssertEqual(counts.sorted(), counts)
            
            // Observation was ended
            await fulfillment(of: [cancellationExpectation], timeout: 2)
        }
        
        try await AsyncTest(test).run { try DatabaseQueue() }
        try await AsyncTest(test).runAtTemporaryDatabasePath { try DatabaseQueue(path: $0) }
        try await AsyncTest(test).runAtTemporaryDatabasePath { try DatabasePool(path: $0) }
    }
    
    func testAsyncAwait_values_cancelled() async throws {
        func test(_ writer: some DatabaseWriter) async throws {
            // We need something to change
            try await writer.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            let cancellationExpectation = expectation(description: "cancelled")
            
            // Launch a task that we'll cancel
            let cancelledTask = Task<String, Error> {
                // Loops until cancelled
                let observation = ValueObservation.trackingConstantRegion(Table("t").fetchCount)
                let cancelledObservation = observation.handleEvents(didCancel: {
                    cancellationExpectation.fulfill()
                })
                for try await _ in cancelledObservation.values(in: writer) { }
                return "cancelled loop"
            }
            
            // Launch the task that cancels
            Task {
                do {
                    let observation = ValueObservation.trackingConstantRegion(Table("t").fetchCount)
                    for try await count in observation.values(in: writer) {
                        if count >= 3 {
                            cancelledTask.cancel()
                            break
                        } else {
                            try await writer.write {
                                try $0.execute(sql: "INSERT INTO t DEFAULT VALUES")
                            }
                        }
                    }
                } catch {
                    XCTFail("Unexpected error: \(error)")
                    cancelledTask.cancel()
                }
            }
            
            // Make sure loop has ended in the cancelled task
            let cancelledValue = try await cancelledTask.value
            XCTAssertEqual(cancelledValue, "cancelled loop")
            
            // Make sure observation was cancelled as well
            await fulfillment(of: [cancellationExpectation], timeout: 2)
        }
        
        try await AsyncTest(test).run { try DatabaseQueue() }
        try await AsyncTest(test).runAtTemporaryDatabasePath { try DatabaseQueue(path: $0) }
        try await AsyncTest(test).runAtTemporaryDatabasePath { try DatabasePool(path: $0) }
    }
    
    // An attempt at finding a regression test for <https://github.com/groue/GRDB.swift/issues/1362>
    func testManyObservations() throws {
        // TODO: Fix flaky test with SQLCipher 3
        #if SQLITE_HAS_CODEC
        if Database.sqliteLibVersionNumber <= 3020001 {
            throw XCTSkip("Skip flaky test with SQLCipher 3")
        }
        #endif
        
        // We'll start many observations
        let observationCount = 100
        dbConfiguration.maximumReaderCount = 5
        
        func test(_ writer: some DatabaseWriter, scheduling scheduler: some ValueObservationScheduler) throws {
            try writer.write {
                try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)")
            }
            let observation = ValueObservation.tracking {
                try Table("t").fetchCount($0)
            }
            
            let initialValueExpectation = self.expectation(description: "initialValue")
#if SQLITE_ENABLE_SNAPSHOT && !SQLITE_DISABLE_SNAPSHOT
            initialValueExpectation.assertForOverFulfill = true
#else
            // ValueObservation on DatabasePool will notify the first value twice
            initialValueExpectation.assertForOverFulfill = false
#endif
            initialValueExpectation.expectedFulfillmentCount = observationCount
            
            let secondValueExpectation = self.expectation(description: "secondValue")
            secondValueExpectation.expectedFulfillmentCount = observationCount
            
            var cancellables: [AnyDatabaseCancellable] = []
            for _ in 0..<observationCount {
                let cancellable = observation.start(in: writer, scheduling: scheduler) { error in
                    XCTFail("Unexpected error: \(error)")
                } onChange: { count in
                    if count == 0 {
                        initialValueExpectation.fulfill()
                    } else {
                        secondValueExpectation.fulfill()
                    }
                }
                cancellables.append(cancellable)
            }
            
            try withExtendedLifetime(cancellables) {
                wait(for: [initialValueExpectation], timeout: 2)
                try writer.write {
                    try $0.execute(sql: "INSERT INTO t DEFAULT VALUES")
                }
                wait(for: [secondValueExpectation], timeout: 2)
            }
        }
        
        try Test(test).run { try (DatabaseQueue(), .immediate) }
        try Test(test).runAtTemporaryDatabasePath { try (DatabaseQueue(path: $0), .immediate) }
        try Test(test).runAtTemporaryDatabasePath { try (DatabasePool(path: $0), .immediate) }
        
        try Test(test).run { try (DatabaseQueue(), .async(onQueue: .main)) }
        try Test(test).runAtTemporaryDatabasePath { try (DatabaseQueue(path: $0), .async(onQueue: .main)) }
        try Test(test).runAtTemporaryDatabasePath { try (DatabasePool(path: $0), .async(onQueue: .main)) }
    }
    
    // An attempt at finding a regression test for <https://github.com/groue/GRDB.swift/issues/1362>
    func testManyObservationsWithLongConcurrentWrite() throws {
        // We'll start many observations
        let observationCount = 100
        dbConfiguration.maximumReaderCount = 5
        
        func test(_ writer: some DatabaseWriter, scheduling scheduler: some ValueObservationScheduler) throws {
            try writer.write {
                try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)")
            }
            let observation = ValueObservation.tracking {
                return try Table("t").fetchCount($0)
            }
            
            let initialValueExpectation = self.expectation(description: "")
#if SQLITE_ENABLE_SNAPSHOT && !SQLITE_DISABLE_SNAPSHOT
            initialValueExpectation.assertForOverFulfill = true
#else
            // ValueObservation on DatabasePool will notify the first value twice
            initialValueExpectation.assertForOverFulfill = false
#endif
            initialValueExpectation.expectedFulfillmentCount = observationCount
            
            let secondValueExpectation = self.expectation(description: "")
            secondValueExpectation.expectedFulfillmentCount = observationCount
            
            let semaphore = DispatchSemaphore(value: 0)
            writer.asyncWriteWithoutTransaction { db in
                semaphore.signal()
                Thread.sleep(forTimeInterval: 0.5)
            }
            semaphore.wait()
            
            var cancellables: [AnyDatabaseCancellable] = []
            for _ in 0..<observationCount {
                let cancellable = observation.start(in: writer, scheduling: scheduler) { error in
                    XCTFail("Unexpected error: \(error)")
                } onChange: { count in
                    if count == 0 {
                        initialValueExpectation.fulfill()
                    } else {
                        secondValueExpectation.fulfill()
                    }
                }
                cancellables.append(cancellable)
            }
            
            try withExtendedLifetime(cancellables) {
                wait(for: [initialValueExpectation], timeout: 2)
                try writer.write {
                    try $0.execute(sql: "INSERT INTO t DEFAULT VALUES")
                }
                wait(for: [secondValueExpectation], timeout: 2)
            }
        }
        
        try Test(test).run { try (DatabaseQueue(), .async(onQueue: .main)) }
        try Test(test).runAtTemporaryDatabasePath { try (DatabaseQueue(path: $0), .async(onQueue: .main)) }
        try Test(test).runAtTemporaryDatabasePath { try (DatabasePool(path: $0), .async(onQueue: .main)) }
        
        try Test(test).run { try (DatabaseQueue(), .immediate) }
        try Test(test).runAtTemporaryDatabasePath { try (DatabaseQueue(path: $0), .immediate) }
        try Test(test).runAtTemporaryDatabasePath { try (DatabasePool(path: $0), .immediate) }
    }
    
    // Regression test for <https://github.com/groue/GRDB.swift/issues/1362>
    func testIssue1362() throws {
        func test(_ writer: some DatabaseWriter) throws {
            try writer.write { try $0.execute(sql: "CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            var cancellables = [AnyDatabaseCancellable]()
            
            // Start an observation and wait until it has installed its
            // transaction observer.
            let installedExpectation = expectation(description: "transaction observer installed")
            let finalExpectation = expectation(description: "final value")
            let initialObservation = ValueObservation.trackingConstantRegion(Table("s").fetchCount)
            let cancellable = initialObservation.start(
                in: writer,
                // Immediate initial value so that the next value comes
                // from the write access that installs the transaction observer.
                scheduling: .immediate,
                onError: { error in XCTFail("Unexpected error: \(error)") },
                onChange: { count in
                    if count == 1 {
                        installedExpectation.fulfill()
                    }
                    if count == 2 {
                        finalExpectation.fulfill()
                    }
                })
            cancellables.append(cancellable)
            try writer.write { try $0.execute(sql: "INSERT INTO s DEFAULT VALUES") } // count = 1
            wait(for: [installedExpectation], timeout: 2)
            
            // Start a write that will trigger initialObservation when we decide.
            let semaphore = DispatchSemaphore(value: 0)
            writer.asyncWriteWithoutTransaction { db in
                semaphore.wait()
                do {
                    try db.execute(sql: "INSERT INTO s DEFAULT VALUES") // count = 2
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
            
            // Start as many observations as there are readers
            for _ in 0..<writer.configuration.maximumReaderCount {
                let observation = ValueObservation.trackingConstantRegion(Table("s").fetchCount)
                let cancellable = observation.start(
                    in: writer,
                    onError: { error in XCTFail("Unexpected error: \(error)") },
                    onChange: { _ in })
                cancellables.append(cancellable)
            }
            
            // Wait until all observations are waiting for the writer so
            // that they can install their transaction observer.
            Thread.sleep(forTimeInterval: 0.5)
            
            // Perform the write that triggers initialObservation
            semaphore.signal()
            
            // initialObservation should get its final value
            wait(for: [finalExpectation], timeout: 2)
            
            withExtendedLifetime(cancellables) {}
        }
        
        try Test(test).runAtTemporaryDatabasePath { try DatabasePool(path: $0) }
    }
#endif
    

    

    

    

    

}
