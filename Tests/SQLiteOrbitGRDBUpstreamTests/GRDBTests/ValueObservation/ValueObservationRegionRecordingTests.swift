// Generated from GRDB 7.11.1 Tests/GRDBTests/ValueObservation/ValueObservationRegionRecordingTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest/ and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class ValueObservationRegionRecordingTests: GRDBTestCase {

    
    func testTupleObservation() throws {
        // Here we just test that user can destructure an observed tuple.
        // I'm completely paranoid about tuple destructuring - I can't wrap my
        // head about the rules that allow or disallow it.
        let dbQueue = try makeDatabaseQueue()
        let observation = ValueObservation.trackingConstantRegion { db -> (Int, String) in
            (0, "")
        }
        _ = observation.start(
            in: dbQueue,
            onError: { _ in },
            onChange: { (int: Int, string: String) in }) // <- destructure
    }
    
    func testVaryingRegionTrackingImmediateScheduling() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write {
            try $0.execute(sql: """
                CREATE TABLE source(name TEXT);
                INSERT INTO source VALUES ('a');
                CREATE TABLE a(value INTEGER);
                CREATE TABLE b(value INTEGER);
                """)
        }
        
        let resultsMutex: Mutex<[Int]> = Mutex([])
        let notificationExpectation = expectation(description: "notification")
        notificationExpectation.assertForOverFulfill = true
        notificationExpectation.expectedFulfillmentCount = 4
        
        let regionsMutex: Mutex<[DatabaseRegion]> = Mutex([])
        let observation = ValueObservation
            .tracking { db -> Int in
                let table = try String.fetchOne(db, sql: "SELECT name FROM source")!
                return try Int.fetchOne(db, sql: "SELECT IFNULL(SUM(value), 0) FROM \(table)")!
            }
            .handleEvents(willTrackRegion: { region in
                regionsMutex.withLock { $0.append(region) }
            })
        
        let observer = observation.start(
            in: dbQueue,
            onError: { error in XCTFail("Unexpected error: \(error)") },
            onChange: { count in
                resultsMutex.withLock { $0.append(count) }
                notificationExpectation.fulfill()
        })
        
        try withExtendedLifetime(observer) {
            try dbQueue.inDatabase { db in
                try db.execute(sql: "INSERT INTO a VALUES (1)") // 1
                try db.execute(sql: "INSERT INTO b VALUES (1)") // -
                try db.execute(sql: "INSERT INTO b VALUES (1)") // -
                try db.execute(sql: "UPDATE source SET name = 'b'") // 2
                try db.execute(sql: "INSERT INTO a VALUES (1)") // -
                try db.execute(sql: "INSERT INTO b VALUES (1)") // 3
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(resultsMutex.load(), [0, 1, 2, 3])
            
            XCTAssertEqual(regionsMutex.load().map(\.description), [
                "a(value),source(name)",
                "b(value),source(name)"])
        }
    }
    
    func testVaryingRegionTrackingAsyncScheduling() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write {
            try $0.execute(sql: """
                CREATE TABLE source(name TEXT);
                INSERT INTO source VALUES ('a');
                CREATE TABLE a(value INTEGER);
                CREATE TABLE b(value INTEGER);
                """)
        }
        
        let resultsMutex: Mutex<[Int]> = Mutex([])
        let notificationExpectation = expectation(description: "notification")
        notificationExpectation.assertForOverFulfill = true
        notificationExpectation.expectedFulfillmentCount = 4
        
        let regionsMutex: Mutex<[DatabaseRegion]> = Mutex([])
        let observation = ValueObservation
            .tracking { db -> Int in
                let table = try String.fetchOne(db, sql: "SELECT name FROM source")!
                return try Int.fetchOne(db, sql: "SELECT IFNULL(SUM(value), 0) FROM \(table)")!
            }
            .handleEvents(willTrackRegion: { region in
                regionsMutex.withLock { $0.append(region) }
            })
        
        let observer = observation.start(
            in: dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in XCTFail("Unexpected error: \(error)") },
            onChange: { count in
                resultsMutex.withLock { $0.append(count) }
                notificationExpectation.fulfill()
        })
        
        try withExtendedLifetime(observer) {
            try dbQueue.inDatabase { db in
                try db.execute(sql: "INSERT INTO a VALUES (1)") // 1
                try db.execute(sql: "INSERT INTO b VALUES (1)") // -
                try db.execute(sql: "INSERT INTO b VALUES (1)") // -
                try db.execute(sql: "UPDATE source SET name = 'b'") // 2
                try db.execute(sql: "INSERT INTO a VALUES (1)") // -
                try db.execute(sql: "INSERT INTO b VALUES (1)") // 3
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(resultsMutex.load(), [0, 1, 2, 3])
            
            XCTAssertEqual(regionsMutex.load().map(\.description), [
                "a(value),source(name)",
                "b(value),source(name)"])
        }
    }
}
