import Foundation
import StructuredQueries
import Testing

@testable import SQLiteCross

@Test
func databasePathIdentifiersMatchTheRustFNV1aRepresentation() {
  #expect(DatabaseIdentifier.stable(for: "hello").rawValue == "a430d84680aabd0b")
}

@Test
func crossProcessDatabaseUsesTheDriversDefaultIdentifier() async throws {
  let identifier = DatabaseIdentifier(rawValue: "driver-default")
  let driver = TestDatabaseDriver(identifier: identifier)
  let database = CrossProcessDatabase(driver: driver)

  #expect(database.id == identifier)
  #expect(try await database.read { $0.accessKind } == .read)
  #expect(try await database.write { $0.accessKind } == .write)
}

@Test
func crossProcessDatabaseCanOverrideItsIdentifier() {
  let driver = TestDatabaseDriver(
    identifier: DatabaseIdentifier(rawValue: "driver-default")
  )
  let override = DatabaseIdentifier(rawValue: "application-defined")

  let database = CrossProcessDatabase(driver: driver, id: override)

  #expect(database.id == override)
}

@Test
func structuredQueryExecutionPreservesBindings() async throws {
  let state = TestDatabaseState()
  let database = CrossProcessDatabase(
    driver: TestDatabaseDriver(
      identifier: .unique(),
      state: state
    )
  )
  let title = "Blob's reminder"

  let changedRowCount = try await database.write { transaction in
    try transaction.execute(
      #sql("INSERT INTO reminders (title) VALUES (\(title, as: String.self))", as: Void.self)
    )
  }

  #expect(changedRowCount == 1)
  let prepared = try #require(state.executedQueries.first).prepare { _ in "?" }
  #expect(prepared.sql == "INSERT INTO reminders (title) VALUES (?)")
  #expect(prepared.bindings == [.text(title)])
}

@Test
func structuredQueryFetchingDecodesRowsAndStopsAfterTheFirst() async throws {
  let state = TestDatabaseState(rows: [[.int(1)], [.int(2)], [.int(3)]])
  let database = CrossProcessDatabase(
    driver: TestDatabaseDriver(identifier: .unique(), state: state)
  )

  let values = try await database.read { transaction in
    try transaction.fetchAll(#sql("SELECT value FROM numbers", as: Int.self))
  }
  #expect(values == [1, 2, 3])
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let first = try await database.read { transaction in
    try transaction.fetchOne(#sql("SELECT value FROM numbers", as: Int.self))
  }
  #expect(first == 1)
  #expect(state.visitedRowCount == 1)
}

private final class TestDatabaseDriver: DatabaseDriver, @unchecked Sendable {
  let defaultIdentifier: DatabaseIdentifier
  let state: TestDatabaseState

  init(
    identifier: DatabaseIdentifier,
    state: TestDatabaseState = TestDatabaseState()
  ) {
    self.defaultIdentifier = identifier
    self.state = state
  }

  func read<Result: Sendable>(
    _ body: @Sendable (borrowing TestDatabaseTransaction) throws -> sending Result
  ) async throws -> sending Result {
    let state = self.state
    let transaction = TestDatabaseTransaction(state: state, accessKind: .read)
    return try body(transaction)
  }

  func write<Result: Sendable>(
    _ body: @Sendable (borrowing TestDatabaseTransaction) throws -> sending Result
  ) async throws -> sending Result {
    let state = self.state
    let transaction = TestDatabaseTransaction(state: state, accessKind: .write)
    return try body(transaction)
  }
}

private struct TestDatabaseTransaction: DatabaseTransaction, ~Copyable, ~Escapable {
  let state: TestDatabaseState
  let accessKind: DatabaseTransactionAccessKind

  @_lifetime(borrow state)
  init(
    state: borrowing TestDatabaseState,
    accessKind: DatabaseTransactionAccessKind
  ) {
    self.state = copy state
    self.accessKind = accessKind
  }

  borrowing func execute(_ query: QueryFragment) throws -> Int {
    state.executedQueries.append(query)
    return 1
  }

  borrowing func query(
    _ query: QueryFragment,
    _ body: (inout TestDatabaseRow) throws -> DatabaseRowIteration
  ) throws {
    for values in state.rows {
      state.visitedRowCount += 1
      var row = TestDatabaseRow(values: values)
      if try body(&row) == .stop {
        return
      }
    }
  }
}

private struct TestDatabaseRow: DatabaseRow {
  let values: [QueryBinding]

  mutating func decode<Value: QueryRepresentable>(
    _ type: Value.Type
  ) throws -> Value.QueryOutput {
    var decoder = TestQueryDecoder(values: values)
    return try Value(decoder: &decoder).queryOutput
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  mutating func decode<each Value: QueryRepresentable>(
    _ type: (repeat each Value).Type
  ) throws -> (repeat (each Value).QueryOutput) {
    var decoder = TestQueryDecoder(values: values)
    return try decoder.decodeColumns((repeat each Value).self)
  }
}

private final class TestDatabaseState: @unchecked Sendable {
  var executedQueries: [QueryFragment] = []
  var rows: [[QueryBinding]]
  var visitedRowCount = 0

  init(rows: [[QueryBinding]] = []) {
    self.rows = rows
  }
}

private struct TestQueryDecoder: QueryDecoder {
  let values: [QueryBinding]
  var currentIndex = 0

  mutating func decode(_ columnType: [UInt8].Type) throws -> [UInt8]? {
    try take(QueryBinding.extractBlob, columnType)
  }

  mutating func decode(_ columnType: Double.Type) throws -> Double? {
    try take(QueryBinding.extractDouble, columnType)
  }

  mutating func decode(_ columnType: Int64.Type) throws -> Int64? {
    try take(QueryBinding.extractInt, columnType)
  }

  mutating func decode(_ columnType: UInt64.Type) throws -> UInt64? {
    try take(QueryBinding.extractUInt, columnType)
  }

  mutating func decode(_ columnType: String.Type) throws -> String? {
    try take(QueryBinding.extractText, columnType)
  }

  mutating func decode(_ columnType: Bool.Type) throws -> Bool? {
    try take(QueryBinding.extractBool, columnType)
  }

  mutating func decode(_ columnType: Int.Type) throws -> Int? {
    try decode(Int64.self).map(Int.init)
  }

  mutating func decode(_ columnType: Date.Type) throws -> Date? {
    try take(QueryBinding.extractDate, columnType)
  }

  mutating func decode(_ columnType: UUID.Type) throws -> UUID? {
    try take(QueryBinding.extractUUID, columnType)
  }

  private mutating func take<Value>(
    _ extract: (QueryBinding) -> Value?,
    _ type: Value.Type
  ) throws -> Value? {
    guard currentIndex < values.count else {
      throw QueryDecodingError.missingRequiredColumn
    }
    let binding = values[currentIndex]
    if binding == .null {
      currentIndex += 1
      return nil
    }
    guard let value = extract(binding) else {
      throw QueryDecodingError.typeMismatch(type)
    }
    currentIndex += 1
    return value
  }
}

extension QueryBinding {
  fileprivate static func extractBlob(_ binding: Self) -> [UInt8]? {
    guard case .blob(let value) = binding else { return nil }
    return value
  }

  fileprivate static func extractDouble(_ binding: Self) -> Double? {
    guard case .double(let value) = binding else { return nil }
    return value
  }

  fileprivate static func extractInt(_ binding: Self) -> Int64? {
    guard case .int(let value) = binding else { return nil }
    return value
  }

  fileprivate static func extractUInt(_ binding: Self) -> UInt64? {
    guard case .uint(let value) = binding else { return nil }
    return value
  }

  fileprivate static func extractText(_ binding: Self) -> String? {
    guard case .text(let value) = binding else { return nil }
    return value
  }

  fileprivate static func extractBool(_ binding: Self) -> Bool? {
    guard case .bool(let value) = binding else { return nil }
    return value
  }

  fileprivate static func extractDate(_ binding: Self) -> Date? {
    guard case .date(let value) = binding else { return nil }
    return value
  }

  fileprivate static func extractUUID(_ binding: Self) -> UUID? {
    guard case .uuid(let value) = binding else { return nil }
    return value
  }
}
