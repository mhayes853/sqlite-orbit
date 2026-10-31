// Generated from GRDB 7.11.1 Tests/GRDBTests/Support/Foundation/FoundationNSNullTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class FoundationNSNullTests: GRDBTestCase {
    
    func testNSNullDatabaseValue() {
        let dbValue = NSNull().databaseValue
        XCTAssert(dbValue.isNull)
    }
    
    func testNSNullFromDatabaseValue() {
        // NSNull.fromDatabaseValue always returns nil
        let dbValue = DatabaseValue.null
        XCTAssertNil(NSNull.fromDatabaseValue(dbValue))
    }
    
    func testNSNullFromDatabaseValueFailure() {
        let databaseValue_Int64 = Int64(1).databaseValue
        let databaseValue_Double = Double(100000.1).databaseValue
        let databaseValue_String = "foo".databaseValue
        let databaseValue_Blob = "bar".data(using: .utf8)!.databaseValue
        XCTAssertNil(NSNull.fromDatabaseValue(databaseValue_Int64))
        XCTAssertNil(NSNull.fromDatabaseValue(databaseValue_Double))
        XCTAssertNil(NSNull.fromDatabaseValue(databaseValue_String))
        XCTAssertNil(NSNull.fromDatabaseValue(databaseValue_Blob))
    }
    
}
