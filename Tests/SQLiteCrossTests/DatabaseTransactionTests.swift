import Foundation
import StructuredQueries
import Testing

@testable import SQLiteCross

@Test
func databasePathIdentifiersUseSHA256() {
  #expect(
    DatabaseIdentifier.stable(for: "hello").rawValue
      == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  )
}

@Test
func crossProcessDatabaseUsesTheDriversDefaultIdentifier() async throws {
  let identifier = DatabaseIdentifier(rawValue: "driver-default")
  let driver = TestDatabaseDriver(identifier: identifier)
  let database = CrossProcessDatabase(driver: driver)

  #expect(database.id == identifier)
  #expect(try await database.read { transaction in acceptsReadTransaction(transaction) })
  #expect(try await database.write { transaction in acceptsWriteTransaction(transaction) })
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

  state.visitedRowCount = 0
  let firstDuringWrite = try await database.write { transaction in
    try transaction.fetchOne(#sql("SELECT value FROM numbers", as: Int.self))
  }
  #expect(firstDuringWrite == 1)
  #expect(state.visitedRowCount == 1)
}

@Test
func structuredStatementsExposeTransactionCapabilities() {
  #expect(acceptsReadStatement(TestRecord.select(\.id)))
  #expect(acceptsWriteStatement(TestRecord.insert { TestRecord(id: 1, title: "Blob") }))
  #expect(acceptsWriteStatement(TestRecord.update { $0.title = "Blob Jr." }))
  #expect(acceptsWriteStatement(TestRecord.delete()))

  let rawRead = #sql("SELECT id FROM testRecords", as: Int.self)
  let rawWrite = #sql("DELETE FROM testRecords", as: Void.self)
  #expect(acceptsReadStatement(rawRead))
  #expect(acceptsWriteStatement(rawRead))
  #expect(acceptsReadStatement(rawWrite))
  #expect(acceptsWriteStatement(rawWrite))
}

@Test
func writeTransactionsCanFetchReturningStatements() async throws {
  let state = TestDatabaseState(rows: [[.int(1)], [.int(2)]])
  let database = CrossProcessDatabase(
    driver: TestDatabaseDriver(identifier: .unique(), state: state)
  )

  let values = try await database.write { transaction in
    try transaction.fetchAll(TestReturningWriteStatement())
  }

  #expect(values == [1, 2])
  #expect(state.visitedRowCount == 2)
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
    _ body: @Sendable (borrowing TestReadTransaction) throws -> sending Result
  ) async throws -> sending Result {
    let state = self.state
    let transaction = TestReadTransaction(state: state)
    return try body(transaction)
  }

  func write<Result: Sendable>(
    _ body: @Sendable (borrowing TestWriteTransaction) throws -> sending Result
  ) async throws -> sending Result {
    let state = self.state
    let transaction = TestWriteTransaction(state: state)
    return try body(transaction)
  }
}

private struct TestReadTransaction: DatabaseReadTransaction, ~Copyable, ~Escapable {
  let state: TestDatabaseState

  @_lifetime(borrow state)
  init(state: borrowing TestDatabaseState) {
    self.state = copy state
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

private struct TestWriteTransaction: DatabaseWriteTransaction, ~Copyable, ~Escapable {
  let state: TestDatabaseState

  @_lifetime(borrow state)
  init(state: borrowing TestDatabaseState) {
    self.state = copy state
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

private func acceptsReadTransaction<Transaction: DatabaseReadTransaction>(
  _ transaction: borrowing Transaction
) -> Bool where Transaction: ~Copyable, Transaction: ~Escapable {
  true
}

private func acceptsWriteTransaction<Transaction: DatabaseWriteTransaction>(
  _ transaction: borrowing Transaction
) -> Bool where Transaction: ~Copyable, Transaction: ~Escapable {
  true
}

private func acceptsReadStatement<S: DatabaseReadStatement>(_ statement: S) -> Bool {
  true
}

private func acceptsWriteStatement<S: DatabaseWriteStatement>(_ statement: S) -> Bool {
  true
}

@Table
private struct TestRecord {
  let id: Int
  var title: String
}

private struct TestReturningWriteStatement: DatabaseWriteStatement {
  typealias QueryValue = Int
  typealias From = Never

  let query: QueryFragment = "UPDATE testRecords SET title = title RETURNING id"
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
