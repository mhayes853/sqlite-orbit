// Generated from GRDB 7.11.1 Tests/GRDBTests/ValueObservation/ValueObservationMapTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class ValueObservationMapTests: GRDBTestCase {
    func testMap() throws {
        let valueObservation = ValueObservation
            .trackingConstantRegion(Table("t").fetchCount)
            .map { "\($0)" }
        
        try assertValueObservation(
            valueObservation,
            records: ["0", "1", "2"],
            setup: { db in
                try db.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)")
        },
            recordedUpdates: { db in
                try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
                try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
        })
    }
    
    func testMapPreservesConfiguration() {
        var observation = ValueObservation.trackingConstantRegion { _ in }
        observation.requiresWriteAccess = true
        
        let mappedObservation = observation.map { _ in }
        XCTAssertEqual(mappedObservation.requiresWriteAccess, observation.requiresWriteAccess)
    }
}
