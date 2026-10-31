// Generated from GRDB 7.11.1 Tests/GRDBTests/Support/Foundation/FoundationUUIDTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import Foundation
import SQLiteOrbitGRDB

class FoundationUUIDTests: GRDBTestCase {
    private func assert(_ value: (any DatabaseValueConvertible)?, isDecodedAs expectedUUID: UUID?) throws {
        try makeDatabaseQueue().read { db in
            if let expectedUUID {
                let decodedUUID = try UUID.fetchOne(db, sql: "SELECT ?", arguments: [value])
                XCTAssertEqual(decodedUUID, expectedUUID)
            } else if value == nil {
                let decodedUUID = try Optional<UUID>.fetchAll(db, sql: "SELECT NULL")[0]
                XCTAssertNil(decodedUUID)
            }
        }
        
        let decodedUUID = UUID.fromDatabaseValue(value?.databaseValue ?? .null)
        XCTAssertEqual(decodedUUID, expectedUUID)
    }
    

    

    
    func testFailure() throws {
        try assert(nil, isDecodedAs: nil)
        try assert(DatabaseValue.null, isDecodedAs: nil)
        try assert(1, isDecodedAs: nil)
        try assert(100000.1, isDecodedAs: nil)
        try assert("56e7d8d3e9e448b6968e8d102833af0", isDecodedAs: nil)
        try assert("56e7d8d3-e9e4-48b6-968e-8d102833af0!", isDecodedAs: nil)
        try assert("foo", isDecodedAs: nil)
        try assert("bar".data(using: .utf8)!, isDecodedAs: nil)
        try assert("abcdefghijklmno".data(using: .utf8)!, isDecodedAs: nil)
        try assert("abcdefghijklmnopq".data(using: .utf8)!, isDecodedAs: nil)
    }
}
