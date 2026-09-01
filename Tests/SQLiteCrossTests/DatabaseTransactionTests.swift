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
func databaseCursorsLendRowsAndDecodeValuesLazily() async throws {
  let state = TestDatabaseState(rows: [[.int(1)], [.int(2)], [.int(3)]])
  let database = CrossProcessDatabase(
    driver: TestDatabaseDriver(identifier: .unique(), state: state)
  )

  let values = try await database.read { transaction in
    var cursor = try transaction.rowCursor(
      #sql("SELECT value FROM numbers", as: Int.self)
    )
    var values: [Int] = []
    while var row = try cursor.next() {
      values.append(try row.decode(Int.self))
    }
    return values
  }

  #expect(values == [1, 2, 3])
  #expect(state.visitedRowCount == 3)

  let decodedValues = try await database.read { transaction in
    var cursor = try transaction.fetchCursor(
      #sql("SELECT value FROM numbers", as: Int.self)
    )
    var values: [Int] = []
    while let value = try cursor.next() {
      values.append(value)
    }
    return values
  }

  #expect(decodedValues == [1, 2, 3])
}

@Test
func databaseCursorsCanBeMappedFilteredAndCompactMappedLazily() async throws {
  let state = TestDatabaseState(rows: [[.int(1)], [.int(2)], [.int(3)]])
  let database = CrossProcessDatabase(
    driver: TestDatabaseDriver(identifier: .unique(), state: state)
  )

  let firstMappedValue = try await database.read { transaction in
    var cursor =
      try transaction.fetchCursor(
        #sql("SELECT value FROM numbers", as: Int.self)
      )
      .filter { $0 > 1 }
      .map { $0 * 10 }
    return try cursor.next()
  }

  #expect(firstMappedValue == 20)
  #expect(state.visitedRowCount == 2)

  state.visitedRowCount = 0
  let compactMappedValues = try await database.read { transaction in
    var cursor =
      try transaction.fetchCursor(
        #sql("SELECT value FROM numbers", as: Int.self)
      )
      .compactMap { value in
        value == 2 ? "two" : nil
      }
    var values: [String] = []
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  #expect(compactMappedValues == ["two"])
  #expect(state.visitedRowCount == 3)
}

@Test
func databaseCursorsSupportLazySequenceAdapters() async throws {
  let state = TestDatabaseState(
    rows: [[.int(1)], [.int(2)], [.int(3)], [.int(4)], [.int(5)]]
  )
  let database = CrossProcessDatabase(
    driver: TestDatabaseDriver(identifier: .unique(), state: state)
  )

  let droppedValues = try await database.read { transaction in
    var cursor =
      try transaction.fetchCursor(
        #sql("SELECT value FROM numbers", as: Int.self)
      )
      .dropFirst(2)
    var values: [Int] = []
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  #expect(droppedValues == [3, 4, 5])
  #expect(state.visitedRowCount == 5)

  state.visitedRowCount = 0
  let firstAfterDropWhile = try await database.read { transaction in
    var cursor =
      try transaction.fetchCursor(
        #sql("SELECT value FROM numbers", as: Int.self)
      )
      .drop { $0 < 3 }
    return try cursor.next()
  }

  #expect(firstAfterDropWhile == 3)
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let prefixedValues = try await database.read { transaction in
    var cursor =
      try transaction.fetchCursor(
        #sql("SELECT value FROM numbers", as: Int.self)
      )
      .prefix(2)
    var values: [Int] = []
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  #expect(prefixedValues == [1, 2])
  #expect(state.visitedRowCount == 2)

  state.visitedRowCount = 0
  let prefixedWhileValues = try await database.read { transaction in
    var cursor =
      try transaction.fetchCursor(
        #sql("SELECT value FROM numbers", as: Int.self)
      )
      .prefix { $0 < 3 }
    var values: [Int] = []
    try cursor.forEach { value in
      values.append(value)
    }
    return values
  }

  #expect(prefixedWhileValues == [1, 2])
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let enumeratedValues = try await database.read { transaction in
    var cursor =
      try transaction.fetchCursor(
        #sql("SELECT value FROM numbers", as: Int.self)
      )
      .prefix(2)
      .enumerated()
    var offsets: [Int] = []
    var values: [Int] = []
    try cursor.forEach { value in
      offsets.append(value.offset)
      values.append(value.element)
    }
    return (offsets, values)
  }

  #expect(enumeratedValues.0 == [0, 1])
  #expect(enumeratedValues.1 == [1, 2])
  #expect(state.visitedRowCount == 2)
}

@Test
func databaseCursorsCanCollectIntoStandardCollections() async throws {
  let state = TestDatabaseState(rows: [[.int(1)], [.int(1)], [.int(2)], [.int(3)]])
  let database = CrossProcessDatabase(
    driver: TestDatabaseDriver(identifier: .unique(), state: state)
  )

  let values = try await database.read { transaction in
    try transaction.fetchCursor(
      #sql("SELECT value FROM numbers", as: Int.self)
    )
    .collect()
  }

  #expect(values == [1, 1, 2, 3])
  #expect(state.visitedRowCount == 4)

  state.visitedRowCount = 0
  let contiguousValues = try await database.read { transaction in
    try transaction.fetchCursor(
      #sql("SELECT value FROM numbers", as: Int.self)
    )
    .collect(as: ContiguousArray<Int>.self)
  }

  #expect(Array(contiguousValues) == [1, 1, 2, 3])
  #expect(state.visitedRowCount == 4)

  state.visitedRowCount = 0
  let uniqueValues = try await database.read { transaction in
    try transaction.fetchCursor(
      #sql("SELECT value FROM numbers", as: Int.self)
    )
    .collect(as: Set<Int>.self)
  }

  #expect(uniqueValues == Set([1, 2, 3]))
  #expect(state.visitedRowCount == 4)

  state.visitedRowCount = 0
  let prefixValues = try await database.read { transaction in
    try transaction.fetchCursor(
      #sql("SELECT value FROM numbers", as: Int.self)
    )
    .prefix(2)
    .collect()
  }

  #expect(prefixValues == [1, 1])
  #expect(state.visitedRowCount == 2)
}

@Test
func databaseCursorsSupportTerminalAlgorithms() async throws {
  let state = TestDatabaseState(
    rows: [[.int(3)], [.int(1)], [.int(4)], [.int(1)], [.int(5)]]
  )
  let database = CrossProcessDatabase(
    driver: TestDatabaseDriver(identifier: .unique(), state: state)
  )

  let count = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).count()
  }
  #expect(count == 5)
  #expect(state.visitedRowCount == 5)

  state.visitedRowCount = 0
  let oddCount = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .count { $0 % 2 == 1 }
  }
  #expect(oddCount == 4)
  #expect(state.visitedRowCount == 5)

  state.visitedRowCount = 0
  let isEmpty = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).isEmpty()
  }
  #expect(!isEmpty)
  #expect(state.visitedRowCount == 1)

  state.visitedRowCount = 0
  let first = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).first()
  }
  #expect(first == 3)
  #expect(state.visitedRowCount == 1)

  state.visitedRowCount = 0
  let firstMatch = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .first { $0 > 3 }
  }
  #expect(firstMatch == 4)
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let containsMatch = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .contains { $0 == 4 }
  }
  #expect(containsMatch)
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let allPositive = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .allSatisfy { $0 > 0 }
  }
  #expect(allPositive)
  #expect(state.visitedRowCount == 5)

  let sum = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .reduce(0, +)
  }
  #expect(sum == 14)

  let collectedSum = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .reduce(into: 0) { result, value in
        result += value
      }
  }
  #expect(collectedSum == 14)

  let minimum = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).min()
  }
  #expect(minimum == 1)

  let maximum = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).max()
  }
  #expect(maximum == 5)

  let reverseMinimum = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).min(by: >)
  }
  #expect(reverseMinimum == 5)

  let reverseMaximum = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).max(by: >)
  }
  #expect(reverseMaximum == 1)

  state.visitedRowCount = 0
  let minimumAndMaximum = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMax()
  }
  #expect(minimumAndMaximum?.min == 1)
  #expect(minimumAndMaximum?.max == 5)
  #expect(state.visitedRowCount == 5)

  let reverseMinimumAndMaximum = try await database.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMax(by: >)
  }
  #expect(reverseMinimumAndMaximum?.min == 5)
  #expect(reverseMinimumAndMaximum?.max == 1)

  state.visitedRowCount = 0
  var didThrow = false
  do {
    _ = try await database.read { transaction in
      try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
        .count { value in
          if value == 4 {
            throw TerminalAlgorithmError.stop
          }
          return true
        }
    }
  } catch is TerminalAlgorithmError {
    didThrow = true
  }
  #expect(didThrow)
  #expect(state.visitedRowCount == 3)

  let emptyState = TestDatabaseState()
  let emptyDatabase = CrossProcessDatabase(
    driver: TestDatabaseDriver(identifier: .unique(), state: emptyState)
  )
  let empty = try await emptyDatabase.read { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).isEmpty()
  }
  #expect(empty)
  #expect(emptyState.visitedRowCount == 0)
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
  typealias RowCursor = TestDatabaseRowCursor

  let state: TestDatabaseState

  @_lifetime(borrow state)
  init(state: borrowing TestDatabaseState) {
    self.state = copy state
  }

  @_lifetime(borrow self)
  borrowing func rowCursor<S: DatabaseReadStatement>(_ statement: S) throws -> TestDatabaseRowCursor
  {
    TestDatabaseRowCursor(state: state)
  }
}

private struct TestWriteTransaction: DatabaseWriteTransaction, ~Copyable, ~Escapable {
  typealias RowCursor = TestDatabaseRowCursor

  let state: TestDatabaseState

  @_lifetime(borrow state)
  init(state: borrowing TestDatabaseState) {
    self.state = copy state
  }

  @_lifetime(borrow self)
  borrowing func rowCursor<S: DatabaseReadStatement>(_ statement: S) throws -> TestDatabaseRowCursor
  {
    TestDatabaseRowCursor(state: state)
  }

  @_lifetime(borrow self)
  borrowing func executeRowCursor<S: DatabaseWriteStatement>(
    _ statement: S
  ) throws -> TestDatabaseRowCursor {
    TestDatabaseRowCursor(state: state)
  }

  borrowing func execute<S: DatabaseWriteStatement>(_ statement: S) throws -> Int {
    state.executedQueries.append(statement.query)
    return 1
  }
}

private struct TestDatabaseRowCursor: DatabaseRowCursor, ~Copyable, ~Escapable {
  typealias Row = TestDatabaseRow

  let state: TestDatabaseState
  var nextIndex = 0

  @_lifetime(borrow state)
  init(state: borrowing TestDatabaseState) {
    self.state = copy state
  }

  mutating func next() throws -> TestDatabaseRow? {
    guard nextIndex < state.rows.count else {
      return nil
    }
    let values = state.rows[nextIndex]
    nextIndex += 1
    state.visitedRowCount += 1
    return TestDatabaseRow(values: values)
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

private enum TerminalAlgorithmError: Error {
  case stop
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
