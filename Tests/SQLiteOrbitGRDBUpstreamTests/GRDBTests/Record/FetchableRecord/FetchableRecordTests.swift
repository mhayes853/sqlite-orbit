// Generated from GRDB 7.11.1 Tests/GRDBTests/Record/FetchableRecord/FetchableRecordTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

private struct Fetched: Hashable{
    var firstName: String
    var lastName: String
}

extension Fetched : FetchableRecord {
    init(row: Row) {
        firstName = row["firstName"]
        lastName = row["lastName"]
    }
}

class FetchableRecordTests: GRDBTestCase {

    func testRowInitializer() {
        let row = Row(["firstName": "Arthur", "lastName": "Martin"])
        let s = Fetched(row: row)
        XCTAssertEqual(s.firstName, "Arthur")
        XCTAssertEqual(s.lastName, "Martin")
    }
    

    
    func testFetchCursorWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched> = """
                SELECT \("Arthur") AS firstName, \("O'Brien") AS lastName
                """
            let cursor = try request.fetchCursor(db)
            let fetched = try cursor.next()!
            XCTAssertEqual(fetched.firstName, "Arthur")
            XCTAssertEqual(fetched.lastName, "O'Brien")
        }
    }
    





    
    func testFetchAllWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched> = """
                SELECT \("Arthur") AS firstName, \("O'Brien") AS lastName
                """
            let array = try request.fetchAll(db)
            XCTAssertEqual(array[0].firstName, "Arthur")
            XCTAssertEqual(array[0].lastName, "O'Brien")
        }
    }
    



    

    
    func testFetchSetWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched> = """
                SELECT \("Arthur") AS firstName, \("O'Brien") AS lastName
                """
            let set = try request.fetchSet(db)
            XCTAssertEqual(set.first!.firstName, "Arthur")
            XCTAssertEqual(set.first!.lastName, "O'Brien")
        }
    }
    





    
    func testFetchOneWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched> = """
                SELECT \("Arthur") AS firstName, \("O'Brien") AS lastName
                """
            let fetched = try request.fetchOne(db)
            XCTAssertEqual(fetched!.firstName, "Arthur")
            XCTAssertEqual(fetched!.lastName, "O'Brien")
        }
    }
    



}
