import Testing

@testable import SQLiteOrbit

#if BuiltInSQLite
  @Test
  func orbitIPCDatabaseIdentifiesTheWritersPathUnlessGivenAnIdentifier() throws {
    try withTestDatabaseFile { file in
      let driver = try SQLitePool(path: file.path)
      let override = OrbitDatabaseIdentifier(rawValue: "application-defined")

      let defaulted = OrbitIPCDatabase(writer: driver, transport: InMemoryIPCTransport())
      let overridden = OrbitIPCDatabase(
        writer: driver,
        identifier: override,
        transport: InMemoryIPCTransport()
      )

      #expect(driver.path == file.path)
      #expect(defaulted.id == .forDatabase(path: file.path))
      #expect(overridden.id == override)
    }
  }
#endif

private let numbersSQL: SQL = "SELECT value FROM numbers"

@Test
func executeBindsInterpolatedValuesAndAsksForACachedStatementUnlessToldNotTo() throws {
  let state = TestDatabaseState()
  let title = "Blob's reminder"

  let changedRowCount = try withTestWrite(state) { transaction in
    try transaction.execute("INSERT INTO reminders (title) VALUES (\(title))")
    try transaction.execute("DELETE FROM reminders", cached: false)
    return transaction.changesCount
  }

  #expect(changedRowCount == 1)
  let prepared = try #require(state.executedQueries.first)
  #expect(prepared.text == "INSERT INTO reminders (title) VALUES (?)")
  #expect(prepared.bindings == [.text(title)])
  #expect(state.executedCachedFlags == [true, false])
}

@Test
func fetchingDecodesRowsLazilyAndStopsAfterTheFirst() throws {
  let state = TestDatabaseState(rows: [[.integer(1)], [.integer(2)], [.integer(3)]])

  let values = try withTestRead(state) { transaction in
    try transaction.fetchAll(numbersSQL, as: Int.self)
  }
  #expect(values == [1, 2, 3])
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let first = try withTestRead(state) { transaction in
    try transaction.fetchOne(numbersSQL, as: Int.self)
  }
  #expect(first == 1)
  #expect(state.visitedRowCount == 1)

  state.visitedRowCount = 0
  let firstDuringWrite = try withTestWrite(state) { transaction in
    try transaction.fetchOne(numbersSQL, as: Int.self)
  }
  #expect(firstDuringWrite == 1)
  #expect(state.visitedRowCount == 1)

  // A row cursor lends each row, and a cursor of values decodes each as it is reached.
  let lent = try withTestRead(state) { transaction in
    var cursor = try transaction.rowCursor(numbersSQL)
    var values: [Int] = []
    while let row = try cursor.next() {
      values.append(try row[0, as: Int.self])
    }
    return values
  }
  #expect(lent == [1, 2, 3])

  let decoded = try withTestRead(state) { transaction in
    var cursor = try transaction.fetchCursor(numbersSQL, as: Int.self)
    var values: [Int] = []
    while let value = try cursor.next() {
      values.append(value)
    }
    return values
  }
  #expect(decoded == [1, 2, 3])
}

@Test
func databaseCursorsCanBeMappedFilteredAndCompactMappedLazily() async throws {
  let state = TestDatabaseState(rows: [[.integer(1)], [.integer(2)], [.integer(3)]])

  let firstMappedValue = try withTestRead(state) { transaction in
    var cursor =
      try transaction.fetchCursor(numbersSQL, as: Int.self)
      .filter { $0 > 1 }
      .map { $0 * 10 }
    return try cursor.next()
  }

  #expect(firstMappedValue == 20)
  #expect(state.visitedRowCount == 2)

  state.visitedRowCount = 0
  let compactMappedValues = try withTestRead(state) { transaction in
    var cursor =
      try transaction.fetchCursor(numbersSQL, as: Int.self)
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
    rows: [[.integer(1)], [.integer(2)], [.integer(3)], [.integer(4)], [.integer(5)]]
  )
  let droppedValues = try withTestRead(state) { transaction in
    var cursor =
      try transaction.fetchCursor(numbersSQL, as: Int.self)
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
      try transaction.fetchCursor(numbersSQL, as: Int.self)
      .drop { $0 < 3 }
    return try cursor.next()
  }

  #expect(firstAfterDropWhile == 3)
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let prefixedValues = try withTestRead(state) { transaction in
    var cursor =
      try transaction.fetchCursor(numbersSQL, as: Int.self)
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
      try transaction.fetchCursor(numbersSQL, as: Int.self)
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
      try transaction.fetchCursor(numbersSQL, as: Int.self)
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
  let state = TestDatabaseState(rows: [[.integer(1)], [.integer(1)], [.integer(2)], [.integer(3)]])

  let values = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .collect()
  }

  #expect(values == [1, 1, 2, 3])
  #expect(state.visitedRowCount == 4)

  state.visitedRowCount = 0
  let contiguousValues = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .collect(as: ContiguousArray<Int>.self)
  }

  #expect(Array(contiguousValues) == [1, 1, 2, 3])
  #expect(state.visitedRowCount == 4)

  state.visitedRowCount = 0
  let uniqueValues = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .collect(as: Set<Int>.self)
  }

  #expect(uniqueValues == Set([1, 2, 3]))
  #expect(state.visitedRowCount == 4)

  state.visitedRowCount = 0
  let prefixValues = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .prefix(2)
      .collect()
  }

  #expect(prefixValues == [1, 1])
  #expect(state.visitedRowCount == 2)
}

@Test
func databaseCursorsSupportTerminalAlgorithms() async throws {
  let state = TestDatabaseState(
    rows: [[.integer(3)], [.integer(1)], [.integer(4)], [.integer(1)], [.integer(5)]]
  )
  let count = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).count()
  }
  #expect(count == 5)
  #expect(state.visitedRowCount == 5)

  state.visitedRowCount = 0
  let oddCount = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .count { $0 % 2 == 1 }
  }
  #expect(oddCount == 4)
  #expect(state.visitedRowCount == 5)

  state.visitedRowCount = 0
  let isEmpty = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).isEmpty()
  }
  #expect(!isEmpty)
  #expect(state.visitedRowCount == 1)

  state.visitedRowCount = 0
  let first = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).first()
  }
  #expect(first == 3)
  #expect(state.visitedRowCount == 1)

  state.visitedRowCount = 0
  let firstMatch = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .first { $0 > 3 }
  }
  #expect(firstMatch == 4)
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let containsMatch = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .contains { $0 == 4 }
  }
  #expect(containsMatch)
  #expect(state.visitedRowCount == 3)

  state.visitedRowCount = 0
  let allPositive = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .allSatisfy { $0 > 0 }
  }
  #expect(allPositive)
  #expect(state.visitedRowCount == 5)

  let sum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .reduce(0, +)
  }
  #expect(sum == 14)

  let collectedSum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .reduce(into: 0) { result, value in
        result += value
      }
  }
  #expect(collectedSum == 14)

  let minimum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).min()
  }
  #expect(minimum == 1)

  let maximum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).max()
  }
  #expect(maximum == 5)

  let reverseMinimum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).min(by: >)
  }
  #expect(reverseMinimum == 5)

  let reverseMaximum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).max(by: >)
  }
  #expect(reverseMaximum == 1)

  state.visitedRowCount = 0
  let minimumAndMaximum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).minMax()
  }
  #expect(minimumAndMaximum?.min == 1)
  #expect(minimumAndMaximum?.max == 5)
  #expect(state.visitedRowCount == 5)

  let reverseMinimumAndMaximum = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).minMax(by: >)
  }
  #expect(reverseMinimumAndMaximum?.min == 5)
  #expect(reverseMinimumAndMaximum?.max == 1)

  state.visitedRowCount = 0
  #expect(throws: TestError.self) {
    _ = try withTestRead(state) { transaction in
      try transaction.fetchCursor(numbersSQL, as: Int.self)
        .count { value in
          if value == 4 {
            throw TestError()
          }
          return true
        }
    }
  }
  #expect(state.visitedRowCount == 3)

  let emptyState = TestDatabaseState()
  let empty = try withTestRead(emptyState) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).isEmpty()
  }
  #expect(empty)
  #expect(emptyState.visitedRowCount == 0)
}

@Test
func databaseCursorsSelectTopKValues() async throws {
  let state = TestDatabaseState(
    rows: [[.integer(3)], [.integer(1)], [.integer(4)], [.integer(1)], [.integer(5)]]
  )

  state.visitedRowCount = 0
  let topTwo = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).topK(2)
  }
  #expect(topTwo == [5, 4])
  #expect(state.visitedRowCount == 5)

  let reverseTopTwo = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).topK(2, by: >)
  }
  #expect(reverseTopTwo == [1, 1])

  // Ranks even values above odd ones, so the two "largest" are 4 and then 5.
  let topTwoEvenFirst = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self)
      .topK(2) { ($0 % 2 == 0 ? 1 : 0, $0) < ($1 % 2 == 0 ? 1 : 0, $1) }
  }
  #expect(topTwoEvenFirst == [4, 5])

  state.visitedRowCount = 0
  let extremes = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).minMaxK(2)
  }
  #expect(extremes.min == [1, 1])
  #expect(extremes.max == [5, 4])
  #expect(state.visitedRowCount == 5)

  let reverseExtremes = try withTestRead(state) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).minMaxK(2, by: >)
  }
  #expect(reverseExtremes.min == [5, 4])
  #expect(reverseExtremes.max == [1, 1])

  let emptyState = TestDatabaseState()
  let emptyTop = try withTestRead(emptyState) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).topK(3)
  }
  #expect(emptyTop.isEmpty)

  let emptyExtremes = try withTestRead(emptyState) { transaction in
    try transaction.fetchCursor(numbersSQL, as: Int.self).minMaxK(3)
  }
  #expect(emptyExtremes.min.isEmpty)
  #expect(emptyExtremes.max.isEmpty)

  // The heap has to agree with a full sort for every `k`, on inputs in arbitrary order.
  let seed: UInt64 = 0x5351_4C49_5445
  var generator = CursorTestRandomGenerator(state: seed)
  for _ in 0..<20 {
    let values = (0..<25).map { _ in Int.random(in: -1000...1000, using: &generator) }
    let shuffledState = TestDatabaseState(rows: values.map { [.integer(Int64($0))] })
    let sorted = values.sorted()
    for k in 0...(values.count + 2) {
      let top = try withTestRead(shuffledState) { transaction in
        try transaction.fetchCursor(numbersSQL, as: Int.self).topK(k)
      }
      #expect(top == sorted.suffix(k).reversed(), "seed=\(seed), k=\(k), input=\(values)")

      let extremes = try withTestRead(shuffledState) { transaction in
        try transaction.fetchCursor(numbersSQL, as: Int.self).minMaxK(k)
      }
      #expect(extremes.min == Array(sorted.prefix(k)), "seed=\(seed), k=\(k), input=\(values)")
      #expect(
        extremes.max == sorted.suffix(k).reversed(),
        "seed=\(seed), k=\(k), input=\(values)"
      )
    }
  }

  #expect(throws: TestError.self) {
    _ = try withTestRead(state) { transaction in
      try transaction.fetchCursor(numbersSQL, as: Int.self)
        .topK(2) { lhs, rhs in
          if lhs == 5 || rhs == 5 {
            throw TestError()
          }
          return lhs < rhs
        }
    }
  }
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

private struct TestReadTransaction: OrbitDatabaseReadTransaction, ~Copyable, ~Escapable {
  typealias RowCursor = TestDatabaseRowCursor

  let state: TestDatabaseState

  @_lifetime(borrow state)
  init(state: borrowing TestDatabaseState) {
    self.state = copy state
  }

  borrowing func rowCursor(_ sql: SQL, cached: Bool) throws -> TestDatabaseRowCursor {
    state.record(sql, through: .rowCursor, cached: cached)
    return TestDatabaseRowCursor(state: state)
  }
}

private struct TestWriteTransaction: OrbitDatabaseWriteTransaction, ~Copyable, ~Escapable {
  typealias RowCursor = TestDatabaseRowCursor

  let state: TestDatabaseState

  @_lifetime(borrow state)
  init(state: borrowing TestDatabaseState) {
    self.state = copy state
  }

  borrowing func rowCursor(_ sql: SQL, cached: Bool) throws -> TestDatabaseRowCursor {
    state.record(sql, through: .rowCursor, cached: cached)
    return TestDatabaseRowCursor(state: state)
  }

  borrowing func executeRowCursor(_ sql: SQL, cached: Bool) throws -> TestDatabaseRowCursor {
    state.record(sql, through: .executeRowCursor, cached: cached)
    return TestDatabaseRowCursor(state: state)
  }

  var changesCount: Int { 1 }

  var lastInsertedRowID: Int64 { 1 }

  borrowing func execute(_ sql: SQL, cached: Bool) throws {
    state.record(sql, through: .execute, cached: cached)
  }
}

// Escapable and copyable, unlike the cursor a real driver lends: it reads from a class rather than
// from a statement borrowed from the transaction, so it has no lifetime to depend on. A `~Escapable`
// conformance would have to give `next()` the protocol's `@_lifetime(&self)`, which an escapable
// `Row` cannot carry.
private struct TestDatabaseRowCursor: OrbitDatabaseRowCursor {
  typealias Row = TestDatabaseRow

  let state: TestDatabaseState
  var nextIndex = 0

  init(state: TestDatabaseState) {
    self.state = state
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

private struct TestDatabaseRow: OrbitDatabaseRow {
  let values: [OrbitDatabaseValue]

  var columnCount: Int { values.count }

  func columnName(at index: Int) -> String { "column\(index)" }

  subscript(index: Int) -> OrbitDatabaseValue { values[index] }
}

/// The queries a fake connection ran and the rows it was told to hand back.
///
/// The fake is read and written from whichever thread a transaction runs on, so its state lives
/// behind a lock rather than an `@unchecked Sendable` promise.
private final class TestDatabaseState: Sendable {
  enum EntryPoint: Equatable {
    case rowCursor, executeRowCursor, execute
  }

  private struct State {
    var executedQueries: [SQL] = []
    var entryPoints: [EntryPoint] = []
    var executedCachedFlags: [Bool] = []
    var rows: [[OrbitDatabaseValue]]
    var visitedRowCount = 0
  }

  private let state: Lock<State>

  var executedQueries: [SQL] {
    get { state.withLock { $0.executedQueries } }
    set { state.withLock { $0.executedQueries = newValue } }
  }

  var entryPoints: [EntryPoint] {
    state.withLock { $0.entryPoints }
  }

  var executedCachedFlags: [Bool] {
    state.withLock { $0.executedCachedFlags }
  }

  func record(_ sql: SQL, through entryPoint: EntryPoint, cached: Bool) {
    state.withLock {
      $0.executedQueries.append(sql)
      $0.entryPoints.append(entryPoint)
      $0.executedCachedFlags.append(cached)
    }
  }

  var rows: [[OrbitDatabaseValue]] {
    get { state.withLock { $0.rows } }
    set { state.withLock { $0.rows = newValue } }
  }

  var visitedRowCount: Int {
    get { state.withLock { $0.visitedRowCount } }
    set { state.withLock { $0.visitedRowCount = newValue } }
  }

  init(rows: [[OrbitDatabaseValue]] = []) {
    self.state = Lock(State(rows: rows))
  }
}

// SplitMix64 keeps the generated corpus reproducible without depending on system entropy.
private struct CursorTestRandomGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

#if StructuredQueries
  import Foundation
  import StructuredQueriesSQLite

  @Test
  func structuredQueryStatementsKeepTheirBindingsAndUseCachedStatements() throws {
    let state = TestDatabaseState()
    let title = "Blob's reminder"

    try withTestWrite(state) { transaction in
      try #sql("INSERT INTO reminders (title) VALUES (\(title, as: String.self))", as: Void.self)
        .execute(transaction)
      try #sql("DELETE FROM reminders", as: Void.self).execute(transaction)
    }

    let prepared = try #require(state.executedQueries.first)
    #expect(prepared.text == "INSERT INTO reminders (title) VALUES (?)")
    #expect(prepared.bindings == [.text(title)])
    #expect(state.executedCachedFlags == [true, true])
  }

  @Test
  func structuredQueryFetchingDecodesRowsAndStopsAfterTheFirst() throws {
    let state = TestDatabaseState(rows: [[.integer(1)], [.integer(2)], [.integer(3)]])
    let numbers = #sql("SELECT value FROM numbers", as: Int.self)

    let values = try withTestRead(state) { transaction in try numbers.fetchAll(transaction) }
    #expect(values == [1, 2, 3])
    #expect(state.visitedRowCount == 3)

    state.visitedRowCount = 0
    let first = try withTestRead(state) { transaction in try numbers.fetchOne(transaction) }
    #expect(first == 1)
    #expect(state.visitedRowCount == 1)

    state.visitedRowCount = 0
    let firstDuringWrite = try withTestWrite(state) { transaction in
      try numbers.fetchOne(transaction)
    }
    #expect(firstDuringWrite == 1)
    #expect(state.visitedRowCount == 1)

    // A structured row decodes Structured Queries values column by column.
    let decoded = try withTestRead(state) { transaction in
      var cursor = try transaction.rowCursor(SQL(fragment: numbers.query))
      var values: [Int] = []
      while var row = try cursor.next() {
        values.append(try row.decode(Int.self))
      }
      return values
    }
    #expect(decoded == [1, 2, 3])

    let cursorValues = try withTestRead(state) { transaction in
      try numbers.fetchCursor(transaction).collect()
    }
    #expect(cursorValues == [1, 2, 3])

    let returned = try withTestWrite(state) { transaction in
      try TestReturningWriteStatement().fetchAll(transaction)
    }
    #expect(returned == [1, 2, 3])
  }

  @Test
  func statementCapabilityIsReadOffTheQueryHierarchy() throws {
    // A select-shaped statement reads, so it runs through `rowCursor` in any transaction. Handing a
    // read transaction a mutation fails to compile, because only a write transaction runs a
    // statement that is not select-shaped:
    //   try TestRecord.delete().execute(readTransaction)
    //   try TestRecord.insert { ... }.returning(\.id).fetchAll(readTransaction)
    let state = TestDatabaseState(rows: [])
    try withTestRead(state) { transaction in
      _ = try TestRecord.select(\.id).fetchAll(transaction)
      _ = try TestRecord.all.fetchAll(transaction)
      _ = try TestRecord.where { $0.id.eq(1) }.fetchAll(transaction)
      // A compound select is a type the query library keeps private, so no conformance could ever
      // name it. It is classified by its protocol, not its identity.
      _ = try TestRecord.select(\.id).union(TestRecord.select(\.id)).fetchAll(transaction)
      _ = try Values { (1, "one") }.fetchAll(transaction)
      // Raw SQL cannot be classified from its type, so a read transaction checks it as it is
      // prepared.
      _ = try #sql("SELECT id FROM testRecords", as: Int.self).fetchAll(transaction)
    }
    #expect(state.entryPoints == Array(repeating: .rowCursor, count: 6))

    // In a write transaction, a select still only reads, while everything else may write.
    let writeState = TestDatabaseState(rows: [])
    try withTestWrite(writeState) { transaction in
      _ = try TestRecord.all.fetchAll(transaction)
      try TestRecord.insert { TestRecord(id: 1, title: "Blob") }.execute(transaction)
      try TestRecord.update { $0.title = "Blob Jr." }.execute(transaction)
      _ = try TestRecord.delete().returning(\.id).fetchAll(transaction)
      try #sql("DELETE FROM testRecords").execute(transaction)
      _ = try #sql("DELETE FROM testRecords RETURNING id", as: Int.self).fetchAll(transaction)
    }
    #expect(
      writeState.entryPoints == [
        .rowCursor, .execute, .execute, .executeRowCursor, .execute, .executeRowCursor
      ]
    )
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

  extension TestDatabaseRow: OrbitDatabaseStructuredRow {
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

  /// Decodes the integers, reals, text and blobs a fake row holds, the only values these tests
  /// store.
  private struct TestQueryDecoder: QueryDecoder {
    let values: [OrbitDatabaseValue]
    var currentIndex = 0

    mutating func decode(_ columnType: [UInt8].Type) throws -> [UInt8]? {
      try take(columnType) { $0.blobValue }
    }

    mutating func decode(_ columnType: Double.Type) throws -> Double? {
      try take(columnType) { $0.realValue }
    }

    mutating func decode(_ columnType: Int64.Type) throws -> Int64? {
      try take(columnType) { $0.integerValue }
    }

    mutating func decode(_ columnType: UInt64.Type) throws -> UInt64? {
      try take(columnType) { $0.integerValue.flatMap(UInt64.init(exactly:)) }
    }

    mutating func decode(_ columnType: String.Type) throws -> String? {
      try take(columnType) { $0.textValue }
    }

    mutating func decode(_ columnType: Bool.Type) throws -> Bool? {
      try take(columnType) { $0.integerValue.map { $0 != 0 } }
    }

    mutating func decode(_ columnType: Int.Type) throws -> Int? {
      try decode(Int64.self).map(Int.init)
    }

    mutating func decode(_ columnType: Date.Type) throws -> Date? {
      try take(columnType) { _ in nil }
    }

    mutating func decode(_ columnType: UUID.Type) throws -> UUID? {
      try take(columnType) { _ in nil }
    }

    private mutating func take<Value>(
      _ type: Value.Type,
      _ extract: (OrbitDatabaseValue) -> Value?
    ) throws -> Value? {
      guard currentIndex < values.count else {
        throw QueryDecodingError.missingRequiredColumn
      }
      let value = values[currentIndex]
      currentIndex += 1
      if value == .null { return nil }
      guard let extracted = extract(value) else {
        throw QueryDecodingError.typeMismatch(type)
      }
      return extracted
    }
  }
#endif
