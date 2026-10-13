// Adapted from GRDB 7.11.1; see LICENSE and provenance.md.
import XCTest
import Foundation
import SQLiteOrbitGRDB

private protocol StrategyProvider {
    static var strategy: DatabaseDataEncodingStrategy { get }
}

private enum StrategyDeferredToData: StrategyProvider {
    static let strategy: DatabaseDataEncodingStrategy = .deferredToData
}

private enum StrategyTextUTF8: StrategyProvider {
    static let strategy: DatabaseDataEncodingStrategy = .text
}

private enum StrategyCustom: StrategyProvider {
    static let strategy: DatabaseDataEncodingStrategy = .custom { _ in "custom" }
}

private struct RecordWithData<Strategy: StrategyProvider>: EncodableRecord, Encodable {
    static func databaseDataEncodingStrategy(for column: String) -> DatabaseDataEncodingStrategy {
        Strategy.strategy
    }
    var data: Data
}

extension RecordWithData: Identifiable {
    var id: Data { data }
}

private struct RecordWithOptionalData<Strategy: StrategyProvider>: EncodableRecord, Encodable {
    static func databaseDataEncodingStrategy(for column: String) -> DatabaseDataEncodingStrategy {
        Strategy.strategy
    }
    var data: Data?
}

extension RecordWithOptionalData: Identifiable {
    var id: Data? { data }
}

class DatabaseDataEncodingStrategyTests: GRDBTestCase {
    let testedDatas = [
        "foo".data(using: .utf8)!,
        Data(),
    ]
    
    private func test<T: EncodableRecord>(
        record: T,
        expectedStorage: DatabaseValue.Storage)
    throws
    {
        var container = PersistenceContainer()
        try record.encode(to: &container)
        if let dbValue = container["data"]?.databaseValue {
            XCTAssertEqual(dbValue.storage, expectedStorage)
        } else {
            XCTAssertEqual(.null, expectedStorage)
        }
    }
    
    private func test<Strategy: StrategyProvider>(
        strategy: Strategy.Type,
        encodesData data: Data,
        as value: some DatabaseValueConvertible)
    throws
    {
        try test(record: RecordWithData<Strategy>(data: data), expectedStorage: value.databaseValue.storage)
        try test(record: RecordWithOptionalData<Strategy>(data: data), expectedStorage: value.databaseValue.storage)
    }
    
    private func testNullEncoding<Strategy: StrategyProvider>(strategy: Strategy.Type) throws {
        try test(record: RecordWithOptionalData<Strategy>(data: nil), expectedStorage: .null)
    }
}

// MARK: - deferredToData

extension DatabaseDataEncodingStrategyTests {
    func testDeferredToData() throws {
        try testNullEncoding(strategy: StrategyDeferredToData.self)
        
        for (data, value) in zip(testedDatas, [
            "foo".data(using: .utf8)!,
            Data(),
            ]) { try test(strategy: StrategyDeferredToData.self, encodesData: data, as: value) }
    }
}

// MARK: - text(UTF8)

extension DatabaseDataEncodingStrategyTests {
    func testTextUTF8() throws {
        try testNullEncoding(strategy: StrategyTextUTF8.self)
        
        for (data, value) in zip(testedDatas, [
            "foo",
            "",
            ]) { try test(strategy: StrategyTextUTF8.self, encodesData: data, as: value) }
    }
}

// MARK: - custom((Data) -> DatabaseValueConvertible?)

extension DatabaseDataEncodingStrategyTests {
    func testCustom() throws {
        try testNullEncoding(strategy: StrategyCustom.self)
        
        for (data, value) in zip(testedDatas, [
            "custom",
            "custom",
            ]) { try test(strategy: StrategyCustom.self, encodesData: data, as: value) }
    }
}

