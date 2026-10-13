// Adapted from GRDB 7.11.1; see LICENSE and provenance.md.
import XCTest
import Foundation
import SQLiteOrbitGRDB

private protocol StrategyProvider {
    static var strategy: DatabaseUUIDEncodingStrategy { get }
}

private enum StrategyDeferredToUUID: StrategyProvider {
    static let strategy: DatabaseUUIDEncodingStrategy = .deferredToUUID
}

private enum StrategyUppercaseString: StrategyProvider {
    static let strategy: DatabaseUUIDEncodingStrategy = .uppercaseString
}

private enum StrategyLowercaseString: StrategyProvider {
    static let strategy: DatabaseUUIDEncodingStrategy = .lowercaseString
}

private struct RecordWithUUID<Strategy: StrategyProvider>: EncodableRecord, Encodable {
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        Strategy.strategy
    }
    
    var uuid: UUID
}

extension RecordWithUUID: Identifiable {
    var id: UUID { uuid }
}

private struct RecordWithOptionalUUID<Strategy: StrategyProvider>: EncodableRecord, Encodable {
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        Strategy.strategy
    }
    
    var uuid: UUID?
}

extension RecordWithOptionalUUID: Identifiable {
    var id: UUID? { uuid }
}

class DatabaseUUIDEncodingStrategyTests: GRDBTestCase {
    private func test<T: EncodableRecord>(
        record: T,
        expectedStorage: DatabaseValue.Storage)
    throws
    {
        var container = PersistenceContainer()
        try record.encode(to: &container)
        if let dbValue = container["uuid"]?.databaseValue {
            XCTAssertEqual(dbValue.storage, expectedStorage)
        } else {
            XCTAssertEqual(.null, expectedStorage)
        }
    }
    
    private func test<Strategy: StrategyProvider>(
        strategy: Strategy.Type,
        encodesUUID uuid: UUID,
        as value: any DatabaseValueConvertible)
    throws {
        try test(record: RecordWithUUID<Strategy>(uuid: uuid), expectedStorage: value.databaseValue.storage)
        try test(record: RecordWithOptionalUUID<Strategy>(uuid: uuid), expectedStorage: value.databaseValue.storage)
    }
    
    private func testNullEncoding<Strategy: StrategyProvider>(strategy: Strategy.Type) throws {
        try test(record: RecordWithOptionalUUID<Strategy>(uuid: nil), expectedStorage: .null)
    }
}

// MARK: - deferredToUUID

extension DatabaseUUIDEncodingStrategyTests {
    func testDeferredToUUID() throws {
        try testNullEncoding(strategy: StrategyDeferredToUUID.self)
        
        try test(
            strategy: StrategyDeferredToUUID.self,
            encodesUUID: UUID(uuidString: "61626364-6566-6768-696A-6B6C6D6E6F70")!,
            as: "abcdefghijklmnop".data(using: .utf8)!)
    }
}

// MARK: - UppercaseString

extension DatabaseUUIDEncodingStrategyTests {
    func testUppercaseString() throws {
        try testNullEncoding(strategy: StrategyUppercaseString.self)
        
        try test(
            strategy: StrategyUppercaseString.self,
            encodesUUID: UUID(uuidString: "61626364-6566-6768-696A-6B6C6D6E6F70")!,
            as: "61626364-6566-6768-696A-6B6C6D6E6F70")
        
        try test(
            strategy: StrategyUppercaseString.self,
            encodesUUID: UUID(uuidString: "56e7d8d3-e9e4-48b6-968e-8d102833af00")!,
            as: "56E7D8D3-E9E4-48B6-968E-8D102833AF00")
        
        let uuid = UUID()
        try test(
            strategy: StrategyUppercaseString.self,
            encodesUUID: uuid,
            as: uuid.uuidString.uppercased()) // Assert stable casing
    }
}

// MARK: - LowercaseString

extension DatabaseUUIDEncodingStrategyTests {
    func testLowercaseString() throws {
        try testNullEncoding(strategy: StrategyLowercaseString.self)
        
        try test(
            strategy: StrategyLowercaseString.self,
            encodesUUID: UUID(uuidString: "61626364-6566-6768-696A-6B6C6D6E6F70")!,
            as: "61626364-6566-6768-696a-6b6c6d6e6f70")
        
        try test(
            strategy: StrategyLowercaseString.self,
            encodesUUID: UUID(uuidString: "56e7d8d3-e9e4-48b6-968e-8d102833af00")!,
            as: "56e7d8d3-e9e4-48b6-968e-8d102833af00")
        
        let uuid = UUID()
        try test(
            strategy: StrategyLowercaseString.self,
            encodesUUID: uuid,
            as: uuid.uuidString.lowercased()) // Assert stable casing
    }
}

