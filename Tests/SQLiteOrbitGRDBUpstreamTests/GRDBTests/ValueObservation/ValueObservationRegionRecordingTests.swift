// Generated from GRDB 7.11.1 Tests/GRDBTests/ValueObservation/ValueObservationRegionRecordingTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
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
    

    

}
