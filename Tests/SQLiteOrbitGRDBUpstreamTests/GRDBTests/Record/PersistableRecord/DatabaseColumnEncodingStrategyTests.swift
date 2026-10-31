// Generated from GRDB 7.11.1 Tests/GRDBTests/Record/PersistableRecord/DatabaseColumnEncodingStrategyTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import Foundation
import SQLiteOrbitGRDB

private struct UseDefaultKeysRecord: PersistableRecord, Encodable {
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .useDefaultKeys }
    var recordID: String
}

private struct ConvertToSnakeCaseRecord: PersistableRecord, Encodable {
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    var recordID: String
}

class DatabaseColumnEncodingStrategyTests: GRDBTestCase {
    func testUseDefaultKeys() throws {
        let record = UseDefaultKeysRecord(recordID: "test")

        var container = PersistenceContainer()
        try record.encode(to: &container)
        XCTAssertNil(container["record_id"]?.databaseValue.storage)
        XCTAssertEqual(container["recordID"]?.databaseValue.storage, "test".databaseValue.storage)
    }

    func testConvertToSnakeCase() throws {
        let record = ConvertToSnakeCaseRecord(recordID: "test")

        var container = PersistenceContainer()
        try record.encode(to: &container)
        XCTAssertNil(container["recordID"]?.databaseValue.storage)
        XCTAssertEqual(container["record_id"]?.databaseValue.storage, "test".databaseValue.storage)
    }
}
