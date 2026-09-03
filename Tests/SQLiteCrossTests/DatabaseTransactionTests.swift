import Foundation
import StructuredQueriesSQLite
import Testing

@testable import SQLiteCross

#if SystemSQLite
  @Test
  func interprocessDatabaseUsesTheDriversDefaultIdentifier() async throws {
    let identifier = DatabaseIdentifier(rawValue: "native-default")
    let driver = try SQLiteQueueDriver(path: ":memory:", identifier: identifier)
    let database = InterprocessDatabase(writer: driver)

    #expect(database.id == identifier)
    #expect(try await database.read { transaction in acceptsReadTransaction(transaction) })
    #expect(try await database.write { transaction in acceptsWriteTransaction(transaction) })
  }

  @Test
  func interprocessDatabaseCanOverrideItsIdentifier() {
    let driver = try! SQLiteQueueDriver(path: ":memory:")
    let override = DatabaseIdentifier(rawValue: "application-defined")

    let database = InterprocessDatabase(writer: driver, id: override)

    #expect(database.id == override)
  }
#endif

@Test
func structuredQueryExecutionPreservesBindings() async throws {
  let state = TestDatabaseState()
  let title = "Blob's reminder"

  let changedRowCount = try withTestWrite(state) { transaction in
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

  let values = try withTestRead(state) { transaction in
    try transaction.fetchAll(#sql("SELECT value FROM numbers", as: Int.self))
  }
  #expect(values == [1, 2, 3])
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let first = try withTestRead(state) { transaction in
    try transaction.fetchOne(#sql("SELECT value FROM numbers", as: Int.self))
  }
  #expect(first == 1)
  #expect(state.visitedRowCount == 1)

  state.visitedRowCount = 0
  let firstDuringWrite = try withTestWrite(state) { transaction in
    try transaction.fetchOne(#sql("SELECT value FROM numbers", as: Int.self))
  }
  #expect(firstDuringWrite == 1)
  #expect(state.visitedRowCount == 1)
}

@Test
func databaseCursorsLendRowsAndDecodeValuesLazily() async throws {
  let state = TestDatabaseState(rows: [[.int(1)], [.int(2)], [.int(3)]])

  let values = try withTestRead(state) { transaction in
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

  let decodedValues = try withTestRead(state) { transaction in
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

  let firstMappedValue = try withTestRead(state) { transaction in
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
  let compactMappedValues = try withTestRead(state) { transaction in
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
  let droppedValues = try withTestRead(state) { transaction in
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
  let firstAfterDropWhile = try withTestRead(state) { transaction in
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
  let prefixedValues = try withTestRead(state) { transaction in
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
  let prefixedWhileValues = try withTestRead(state) { transaction in
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
  let enumeratedValues = try withTestRead(state) { transaction in
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

  let values = try withTestRead(state) { transaction in
    try transaction.fetchCursor(
      #sql("SELECT value FROM numbers", as: Int.self)
    )
    .collect()
  }

  #expect(values == [1, 1, 2, 3])
  #expect(state.visitedRowCount == 4)

  state.visitedRowCount = 0
  let contiguousValues = try withTestRead(state) { transaction in
    try transaction.fetchCursor(
      #sql("SELECT value FROM numbers", as: Int.self)
    )
    .collect(as: ContiguousArray<Int>.self)
  }

  #expect(Array(contiguousValues) == [1, 1, 2, 3])
  #expect(state.visitedRowCount == 4)

  state.visitedRowCount = 0
  let uniqueValues = try withTestRead(state) { transaction in
    try transaction.fetchCursor(
      #sql("SELECT value FROM numbers", as: Int.self)
    )
    .collect(as: Set<Int>.self)
  }

  #expect(uniqueValues == Set([1, 2, 3]))
  #expect(state.visitedRowCount == 4)

  state.visitedRowCount = 0
  let prefixValues = try withTestRead(state) { transaction in
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
  let count = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).count()
  }
  #expect(count == 5)
  #expect(state.visitedRowCount == 5)

  state.visitedRowCount = 0
  let oddCount = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .count { $0 % 2 == 1 }
  }
  #expect(oddCount == 4)
  #expect(state.visitedRowCount == 5)

  state.visitedRowCount = 0
  let isEmpty = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).isEmpty()
  }
  #expect(!isEmpty)
  #expect(state.visitedRowCount == 1)

  state.visitedRowCount = 0
  let first = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).first()
  }
  #expect(first == 3)
  #expect(state.visitedRowCount == 1)

  state.visitedRowCount = 0
  let firstMatch = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .first { $0 > 3 }
  }
  #expect(firstMatch == 4)
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let containsMatch = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .contains { $0 == 4 }
  }
  #expect(containsMatch)
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let allPositive = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .allSatisfy { $0 > 0 }
  }
  #expect(allPositive)
  #expect(state.visitedRowCount == 5)

  let sum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .reduce(0, +)
  }
  #expect(sum == 14)

  let collectedSum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .reduce(into: 0) { result, value in
        result += value
      }
  }
  #expect(collectedSum == 14)

  let minimum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).min()
  }
  #expect(minimum == 1)

  let maximum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).max()
  }
  #expect(maximum == 5)

  let reverseMinimum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).min(by: >)
  }
  #expect(reverseMinimum == 5)

  let reverseMaximum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).max(by: >)
  }
  #expect(reverseMaximum == 1)

  state.visitedRowCount = 0
  let minimumAndMaximum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMax()
  }
  #expect(minimumAndMaximum?.min == 1)
  #expect(minimumAndMaximum?.max == 5)
  #expect(state.visitedRowCount == 5)

  let reverseMinimumAndMaximum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMax(by: >)
  }
  #expect(reverseMinimumAndMaximum?.min == 5)
  #expect(reverseMinimumAndMaximum?.max == 1)

  state.visitedRowCount = 0
  var didThrow = false
  do {
    _ = try withTestRead(state) { transaction in
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
  let empty = try withTestRead(emptyState) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).isEmpty()
  }
  #expect(empty)
  #expect(emptyState.visitedRowCount == 0)
}

@Test
func databaseCursorsSelectTopKValues() async throws {
  let state = TestDatabaseState(
    rows: [[.int(3)], [.int(1)], [.int(4)], [.int(1)], [.int(5)]]
  )

  state.visitedRowCount = 0
  let topTwo = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).topK(2)
  }
  #expect(topTwo == [5, 4])
  #expect(state.visitedRowCount == 5)

  let topNone = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).topK(0)
  }
  #expect(topNone.isEmpty)

  let topBeyondCount = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).topK(10)
  }
  #expect(topBeyondCount == [5, 4, 3, 1, 1])

  let reverseTopTwo = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).topK(2, by: >)
  }
  #expect(reverseTopTwo == [1, 1])

  // Ranks even values above odd ones, so the two "largest" are 4 and then 5.
  let topTwoEvenFirst = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
      .topK(2) { ($0 % 2 == 0 ? 1 : 0, $0) < ($1 % 2 == 0 ? 1 : 0, $1) }
  }
  #expect(topTwoEvenFirst == [4, 5])

  state.visitedRowCount = 0
  let extremes = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMaxK(2)
  }
  #expect(extremes.min == [1, 1])
  #expect(extremes.max == [5, 4])
  #expect(state.visitedRowCount == 5)

  let reverseExtremes = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMaxK(2, by: >)
  }
  #expect(reverseExtremes.min == [5, 4])
  #expect(reverseExtremes.max == [1, 1])

  let overlappingExtremes = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMaxK(10)
  }
  #expect(overlappingExtremes.min == [1, 1, 3, 4, 5])
  #expect(overlappingExtremes.max == [5, 4, 3, 1, 1])

  let noExtremes = try withTestRead(state) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMaxK(0)
  }
  #expect(noExtremes.min.isEmpty)
  #expect(noExtremes.max.isEmpty)

  let emptyState = TestDatabaseState()
  let emptyTop = try withTestRead(emptyState) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).topK(3)
  }
  #expect(emptyTop.isEmpty)

  let emptyExtremes = try withTestRead(emptyState) { transaction in
    try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMaxK(3)
  }
  #expect(emptyExtremes.min.isEmpty)
  #expect(emptyExtremes.max.isEmpty)

  // The heap has to agree with a full sort for every `k`, on inputs in arbitrary order.
  var generator = SystemRandomNumberGenerator()
  for _ in 0..<20 {
    let values = (0..<25).map { _ in Int.random(in: -1000...1000, using: &generator) }
    let shuffledState = TestDatabaseState(rows: values.map { [.int(Int64($0))] })
    let sorted = values.sorted()
    for k in 0...(values.count + 2) {
      let top = try withTestRead(shuffledState) { transaction in
        try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).topK(k)
      }
      #expect(top == sorted.suffix(k).reversed())

      let extremes = try withTestRead(shuffledState) { transaction in
        try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self)).minMaxK(k)
      }
      #expect(extremes.min == Array(sorted.prefix(k)))
      #expect(extremes.max == sorted.suffix(k).reversed())
    }
  }

  var didThrow = false
  do {
    _ = try withTestRead(state) { transaction in
      try transaction.fetchCursor(#sql("SELECT value FROM numbers", as: Int.self))
        .topK(2) { lhs, rhs in
          if lhs == 5 || rhs == 5 {
            throw TerminalAlgorithmError.stop
          }
          return lhs < rhs
        }
    }
  } catch is TerminalAlgorithmError {
    didThrow = true
  }
  #expect(didThrow)
}

@Test
func statementCapabilityIsReadOffTheQueryHierarchy() {
  // Building a read query is only possible for a select-shaped statement, so a read transaction
  // cannot be handed a mutation. Every one of these would fail to compile as a read query:
  //   DatabaseQuery<DatabaseReadAccess>(TestRecord.delete())
  //   DatabaseQuery<DatabaseReadAccess>(TestRecord.insert { ... })
  let reads: [DatabaseQuery<DatabaseReadAccess>] = [
    DatabaseQuery(TestRecord.select(\.id)),
    DatabaseQuery(TestRecord.all),
    DatabaseQuery(TestRecord.where { $0.id.eq(1) }),
    // A compound select is a type the query library keeps private, so no conformance could ever
    // name it. It is classified by its protocol, not its identity.
    DatabaseQuery(TestRecord.select(\.id).union(TestRecord.select(\.id))),
    DatabaseQuery(Values { (1, "one") }),
    // Raw SQL cannot be classified from its type, so it is accepted on both sides.
    DatabaseQuery(#sql("SELECT id FROM testRecords", as: Int.self))
  ]
  #expect(reads.allSatisfy { !$0.fragment.isEmpty })

  let writes: [DatabaseQuery<DatabaseWriteAccess>] = [
    DatabaseQuery(TestRecord.insert { TestRecord(id: 1, title: "Blob") }),
    DatabaseQuery(TestRecord.update { $0.title = "Blob Jr." }),
    DatabaseQuery(TestRecord.delete()),
    // Reads are runnable in a write transaction too.
    DatabaseQuery(TestRecord.all),
    DatabaseQuery(#sql("DELETE FROM testRecords", as: Void.self))
  ]
  #expect(writes.allSatisfy { !$0.fragment.isEmpty })
}

@Test
func writeTransactionsCanFetchReturningStatements() async throws {
  let state = TestDatabaseState(rows: [[.int(1)], [.int(2)]])

  let values = try withTestWrite(state) { transaction in
    try transaction.fetchAll(TestReturningWriteStatement())
  }

  #expect(values == [1, 2])
  #expect(state.visitedRowCount == 2)
}

private func withTestRead<Result>(
  _ state: TestDatabaseState,
  _ body: (borrowing TestReadTransaction) throws -> Result
) rethrows -> Result {
  try body(TestReadTransaction(state: state))
}

private func withTestWrite<Result>(
  _ state: TestDatabaseState,
  _ body: (borrowing TestWriteTransaction) throws -> Result
) rethrows -> Result {
  try body(TestWriteTransaction(state: state))
}

private struct TestReadTransaction: DatabaseReadTransaction, ~Copyable, ~Escapable {
  typealias RowCursor = TestDatabaseRowCursor

  let state: TestDatabaseState

  @_lifetime(borrow state)
  init(state: borrowing TestDatabaseState) {
    self.state = copy state
  }

  @_lifetime(borrow self)
  borrowing func rowCursor(
    _ query: DatabaseQuery<DatabaseReadAccess>,
    cached: Bool
  ) throws -> TestDatabaseRowCursor {
    state.executedQueries.append(query.fragment)
    return TestDatabaseRowCursor(state: state)
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
  borrowing func rowCursor(
    _ query: DatabaseQuery<DatabaseReadAccess>,
    cached: Bool
  ) throws -> TestDatabaseRowCursor {
    state.executedQueries.append(query.fragment)
    return TestDatabaseRowCursor(state: state)
  }

  @_lifetime(borrow self)
  borrowing func rowCursor(
    _ query: DatabaseQuery<DatabaseWriteAccess>,
    cached: Bool
  ) throws -> TestDatabaseRowCursor {
    state.executedQueries.append(query.fragment)
    return TestDatabaseRowCursor(state: state)
  }

  borrowing func execute(_ query: DatabaseQuery<DatabaseWriteAccess>) throws -> Int {
    state.executedQueries.append(query.fragment)
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

@Table
private struct TestRecord {
  let id: Int
  var title: String
}

private struct TestReturningWriteStatement: Statement {
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
