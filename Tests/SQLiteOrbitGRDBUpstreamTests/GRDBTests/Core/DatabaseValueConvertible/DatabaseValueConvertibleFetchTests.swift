// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseValueConvertible/DatabaseValueConvertibleFetchTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

// A type that adopts DatabaseValueConvertible but does not adopt StatementColumnConvertible
private struct Fetched: DatabaseValueConvertible, Hashable {
    let int: Int
    init(int: Int) {
        self.int = int
    }
    var databaseValue: DatabaseValue { int.databaseValue }
    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Fetched? {
        guard let int = Int.fromDatabaseValue(dbValue) else {
            return nil
        }
        return Fetched(int: int)
    }
}

class DatabaseValueConvertibleFetchTests: GRDBTestCase {
    
    // MARK: - DatabaseValueConvertible.fetch
    

    
    func testFetchCursorWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched> = "SELECT \(42)"
            let cursor = try request.fetchCursor(db)
            let fetched = try cursor.next()!
            XCTAssertEqual(fetched.int, 42)
        }
    }
    

    

    

    
    func testFetchAllWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched> = "SELECT \(42)"
            let array = try request.fetchAll(db)
            XCTAssertEqual(array[0].int, 42)
        }
    }
    

    

    

    
    func testFetchSetWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched> = "SELECT \(42)"
            let set = try request.fetchSet(db)
            XCTAssertEqual(set.first!.int, 42)
        }
    }
    

    

    

    
    func testFetchOneWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched> = "SELECT \(42)"
            let fetched = try request.fetchOne(db)
            XCTAssertEqual(fetched!.int, 42)
        }
    }
    

    

    
    // MARK: - Optional<DatabaseValueConvertible>.fetch
    

    
    func testOptionalFetchCursorWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched?> = "SELECT \(42)"
            let cursor = try request.fetchCursor(db)
            let fetched = try cursor.next()!
            XCTAssertEqual(fetched!.int, 42)
        }
    }
    

    

    

    
    func testOptionalFetchAllWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched?> = "SELECT \(42)"
            let array = try request.fetchAll(db)
            XCTAssertEqual(array[0]!.int, 42)
        }
    }
    

    

    

    
    func testOptionalFetchSetWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched?> = "SELECT \(42)"
            let set = try request.fetchSet(db)
            XCTAssertEqual(set.first!!.int, 42)
        }
    }
    

    

    

    
    func testOptionalFetchOneWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let request: SQLRequest<Fetched?> = "SELECT \(42)"
            let fetched = try request.fetchOne(db)
            XCTAssertEqual(fetched!!.int, 42)
        }
    }
    

    

}
