// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseValueConvertible/DatabaseValueConvertibleDecodableTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseValueConvertibleDecodableTests: GRDBTestCase {

    

    

    

    

    

    

    


    func testCustomDatabaseValueConvertible() throws {
        struct Value : Decodable, DatabaseValueConvertible {
            let string: String
            
            var databaseValue: DatabaseValue {
                preconditionFailure("not tested")
            }
            
            static func fromDatabaseValue(_ databaseValue: DatabaseValue) -> Value? {
                if let string = String.fromDatabaseValue(databaseValue) {
                    return Value(string: string + " (DatabaseValueConvertible)")
                } else {
                    return nil
                }
            }
        }
        
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let value = try Value.fetchOne(db, sql: "SELECT 'foo'")!
            XCTAssertEqual(value.string, "foo (DatabaseValueConvertible)")
        }
    }
    
    func testDecodableRawRepresentableFetchingMethod() throws {
        enum Value : String, Decodable, DatabaseValueConvertible {
            case foo, bar
        }
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let value = try Value.fetchOne(db, sql: "SELECT 'foo'")!
            XCTAssertEqual(value, .foo)
        }
    }
    

}
