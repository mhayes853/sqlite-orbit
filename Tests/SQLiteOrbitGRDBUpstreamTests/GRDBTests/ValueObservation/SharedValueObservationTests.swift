// Generated from GRDB 7.11.1 Tests/GRDBTests/ValueObservation/SharedValueObservationTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class SharedValueObservationTests: GRDBTestCase {

    

    

    

    
#if canImport(Combine)
    func test_immediate_publisher() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
            }
        }
        
        let publisher = ValueObservation
            .tracking(Table("player").fetchCount)
            .shared(
                in: dbQueue,
                scheduling: .immediate)
            .publisher()
        
        do {
            let recorder = publisher.record()
            try XCTAssertEqual(recorder.next().get(), 0)
            try dbQueue.write { try $0.execute(sql: "INSERT INTO player DEFAULT VALUES")}
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 1)
        }
        
        do {
            let recorder = publisher.record()
            try XCTAssertEqual(recorder.next().get(), 1)
            try dbQueue.write { try $0.execute(sql: "INSERT INTO player DEFAULT VALUES")}
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 2)
        }
    }
#endif
    

    

    

    

    
#if canImport(Combine)
    func test_async_publisher() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
            }
        }
        
        let publisher = ValueObservation
            .tracking(Table("player").fetchCount)
            .shared(in: dbQueue) // default async
            .publisher()
        
        do {
            let recorder = publisher.record()
            try XCTAssert(recorder.availableElements.get().isEmpty)
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 0)
            try dbQueue.write { try $0.execute(sql: "INSERT INTO player DEFAULT VALUES")}
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 1)
        }
        
        do {
            let recorder = publisher.record()
            try XCTAssert(recorder.availableElements.get().isEmpty)
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 1)
            try dbQueue.write { try $0.execute(sql: "INSERT INTO player DEFAULT VALUES")}
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 2)
        }
    }
#endif
    

    

    
#if canImport(Combine)
    func test_task_publisher() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
            }
        }
        
        let publisher = ValueObservation
            .tracking(Table("player").fetchCount)
            .shared(in: dbQueue, scheduling: .task)
            .publisher()
        
        do {
            let recorder = publisher.record()
            try XCTAssert(recorder.availableElements.get().isEmpty)
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 0)
            try dbQueue.write { try $0.execute(sql: "INSERT INTO player DEFAULT VALUES")}
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 1)
        }
        
        do {
            let recorder = publisher.record()
            try XCTAssert(recorder.availableElements.get().isEmpty)
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 1)
            try dbQueue.write { try $0.execute(sql: "INSERT INTO player DEFAULT VALUES")}
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 2)
        }
    }
#endif
    


#if canImport(Combine)
    func test_error_recovery_observationLifetime() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
            }
        }
        
        let log = Log()
        let fetchErrorMutex: Mutex<Error?> = Mutex(nil)
        let publisher = ValueObservation
            .tracking { db -> Int in
                try fetchErrorMutex.withLock { error in
                    if let error { throw error }
                }
                return try Table("player").fetchCount(db)
            }
            .print(to: log)
            .shared(in: dbQueue, extent: .observationLifetime)
            .publisher()
        
        do {
            let recorder1 = publisher.record()
            let recorder2 = publisher.record()
            
            try XCTAssertEqual(wait(for: recorder1.next(), timeout: 1), 0)
            try XCTAssertEqual(wait(for: recorder2.next(), timeout: 1), 0)
            
            fetchErrorMutex.store(TestError())
            try dbQueue.write { try $0.execute(sql: "INSERT INTO player DEFAULT VALUES")}
            
            if case .finished = try wait(for: recorder1.completion, timeout: 1) { XCTFail("Expected error") }
            if case .finished = try wait(for: recorder2.completion, timeout: 1) { XCTFail("Expected error") }
            XCTAssertEqual(log.flush(), [
                "start", "fetch", "tracked region: player(*)", "value: 0",
                "database did change", "fetch", "failure: TestError()"])
        }
        
        do {
            let recorder = publisher.record()
            if case .finished = try wait(for: recorder.completion, timeout: 1) { XCTFail("Expected error") }
            XCTAssertEqual(log.flush(), [])
        }
        
        do {
            fetchErrorMutex.store(nil)
            let recorder = publisher.record()
            if case .finished = try wait(for: recorder.completion, timeout: 1) { XCTFail("Expected error") }
            XCTAssertEqual(log.flush(), [])
        }
    }
#endif
    
#if canImport(Combine)
    func test_error_recovery_whileObserved() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "player") { t in
                t.autoIncrementedPrimaryKey("id")
            }
        }
        
        let log = Log()
        let fetchErrorMutex: Mutex<Error?> = Mutex(nil)
        let publisher = ValueObservation
            .tracking { db -> Int in
                try fetchErrorMutex.withLock { error in
                    if let error { throw error }
                }
                return try Table("player").fetchCount(db)
            }
            .print(to: log)
            .shared(in: dbQueue, extent: .whileObserved)
            .publisher()
        
        do {
            let recorder1 = publisher.record()
            let recorder2 = publisher.record()
            
            try XCTAssertEqual(wait(for: recorder1.next(), timeout: 1), 0)
            try XCTAssertEqual(wait(for: recorder2.next(), timeout: 1), 0)
            
            fetchErrorMutex.store(TestError())
            try dbQueue.write { try $0.execute(sql: "INSERT INTO player DEFAULT VALUES")}
            
            if case .finished = try wait(for: recorder1.completion, timeout: 1) { XCTFail("Expected error") }
            if case .finished = try wait(for: recorder2.completion, timeout: 1) { XCTFail("Expected error") }
            XCTAssertEqual(log.flush(), [
                "start", "fetch", "tracked region: player(*)", "value: 0",
                "database did change", "fetch", "failure: TestError()"])
        }
        
        do {
            let recorder = publisher.record()
            if case .finished = try wait(for: recorder.completion, timeout: 1) { XCTFail("Expected error") }
            XCTAssertEqual(log.flush(), ["start", "fetch", "failure: TestError()"])
        }
        
        do {
            fetchErrorMutex.store(nil)
            let recorder = publisher.record()
            try XCTAssertEqual(wait(for: recorder.next(), timeout: 1), 1)
            XCTAssertEqual(log.flush(), ["start", "fetch", "tracked region: player(*)", "value: 1"])
        }
    }
#endif
    

    

}

private class Log: TextOutputStream {
    var strings: [String] = []
    let lock = NSLock()
    
    func write(_ string: String) {
        lock.lock()
        strings.append(string)
        lock.unlock()
    }
    
    @discardableResult
    func flush() -> [String] {
        lock.lock()
        let result = strings
        strings = []
        lock.unlock()
        return result
    }
}

private struct TestError: Error { }
