#if BuiltInSQLite
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  #if StructuredQueries
    import StructuredQueriesSQLite
  #endif

  // `repeated(text, count)`, which repeats its text.
  private let repeatText:
    @Sendable (borrowing SQLiteFunctionArguments) throws -> OrbitDatabaseValue = {
      arguments in
      guard case .text(let text) = arguments[0], case .integer(let count) = arguments[1] else {
        throw FunctionFailure()
      }
      return .text(String(repeating: text, count: Int(count)))
    }

  private func register(
    _ configuration: inout SQLiteConfiguration,
    repeated: Bool = false,
    longest: Bool = false
  ) {
    if repeated {
      configuration.registerFunction(
        "repeated",
        argumentCount: 2,
        flags: [.deterministic],
        repeatText
      )
    }
    if longest {
      configuration.registerAggregateFunction("longest", argumentCount: 1, LongestText())
    }
  }

  /// Creates `notes` and fills it with a title of each of the lengths `lengths`.
  private func seedNotes(_ database: some OrbitDatabaseWriter, lengths: [Int]) async throws {
    try await database.write { transaction in
      try transaction.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
      for (id, length) in lengths.enumerated() {
        try transaction.execute(
          "INSERT INTO notes VALUES (\(id + 1), \(String(repeating: "x", count: length)))"
        )
      }
    }
  }

  @Test
  func scalarAndAggregateFunctionsRunOnEveryConnectionAPoolOpens() async throws {
    var configuration = SQLiteConfiguration.default
    register(&configuration, repeated: true, longest: true)

    try await withPooledDatabase(configuration: configuration) { database in
      try await seedNotes(database, lengths: [2, 4, 3])

      let scalar = try await database.fetchAll(
        sql: "SELECT repeated(title, 3) FROM notes WHERE id = 1",
        as: String.self
      )
      #expect(scalar == ["xxxxxx"])

      // Force the pool past its first reader. A function installed on one connection only would
      // fail here with "no such function".
      let aggregates = try await concurrentReads(8, of: database) { transaction in
        try transaction.fetchOne("SELECT longest(title) FROM notes", as: String.self)
      }
      #expect(aggregates.allSatisfy { $0 == "xxxx" })
    }
  }

  @Test
  func functionsReceiveEveryStorageClassAndReturnValues() async throws {
    var configuration = SQLiteConfiguration.default
    configuration.registerFunction("describe", argumentCount: nil, flags: [.deterministic]) {
      arguments in
      var parts: [String] = []
      for index in 0..<arguments.count {
        switch arguments[index] {
        case .null: parts.append("null")
        case .integer(let value): parts.append("integer \(value)")
        case .real(let value): parts.append("real \(value)")
        case .text(let value): parts.append("text \(value)")
        case .blob(let value): parts.append("blob \(value.count)")
        }
      }
      return .text(parts.joined(separator: ", "))
    }
    configuration.registerFunction("echo", argumentCount: 1) { $0[0] }
    let database = try inMemoryDatabase(configuration: configuration)

    let (described, none, echoed, emptyBlob) = try await database.read { transaction in
      (
        // A zero-length blob has no buffer behind it, and must still be read.
        try transaction.fetchOne("SELECT describe(NULL, 1, 2.5, 'a', x'0102', x'')") {
          $0[0].textValue
        },
        try transaction.fetchOne("SELECT describe()") { $0[0].textValue },
        try transaction.fetchAll(
          "SELECT echo(column1) FROM (VALUES (NULL), (1), (2.5), ('a'), (x'00'))"
        ) { $0[0] },
        // An empty blob result stays a blob rather than becoming NULL.
        try transaction.fetchOne("SELECT typeof(echo(x''))", as: String.self)
      )
    }
    #expect(described == "null, integer 1, real 2.5, text a, blob 2, blob 0")
    #expect(none == "")
    #expect(echoed == [nil, 1, 2.5, "a", .blob([0])])
    #expect(emptyBlob == "blob")
  }

  @Test(arguments: ["", "plain text", "日本語", "before\u{0}after"])
  func functionTextRoundTripsExactly(_ text: String) async throws {
    var configuration = SQLiteConfiguration.default
    register(&configuration, repeated: true)
    let database = try inMemoryDatabase(configuration: configuration)
    let value = try await database.read { transaction in
      try transaction.fetchOne("SELECT repeated(\(text), 2)", as: String.self)
    }
    #expect(value == text + text)
  }

  @Test
  func functionFailuresBecomeStatementErrors() async throws {
    var configuration = SQLiteConfiguration.default
    configuration.registerFunction("failing", argumentCount: 0) { _ in throw FunctionFailure() }
    configuration.registerAggregateFunction(
      "failingStep",
      argumentCount: 1,
      FailingAccumulator(failsInStep: true)
    )
    configuration.registerAggregateFunction(
      "failingFinish",
      argumentCount: 1,
      FailingAccumulator(failsInStep: false)
    )
    let database = try inMemoryDatabase(configuration: configuration)
    try await seedNotes(database, lengths: [1, 2])

    for sql in [
      "SELECT failing()", "SELECT failingStep(id) FROM notes", "SELECT failingFinish(id) FROM notes"
    ] {
      let error = await #expect(throws: SQLiteError.self) {
        try await database.fetchOne(sql: sql, as: Int.self)
      }
      #expect(error?.message?.contains("FunctionFailure") == true)
    }
  }

  @Test
  func aggregatesSpanManyRowsAndManyGroups() async throws {
    var configuration = SQLiteConfiguration.default
    register(&configuration, longest: true)
    let database = try inMemoryDatabase(configuration: configuration)
    // A large group, so the aggregation holds many rows before it finishes.
    try await seedNotes(database, lengths: (1...500).map { $0 % 40 + 1 })

    let longest = try await database.fetchOne(
      sql: "SELECT longest(title) FROM notes",
      as: String.self
    )
    #expect(longest?.count == 40)

    // A separate aggregation per group exercises SQLite's per-aggregation context slot.
    let perGroup = try await database.read { transaction in
      try transaction.fetchAll(
        "SELECT id % 3, longest(title) FROM notes GROUP BY id % 3 ORDER BY id % 3"
      ) { ($0[0].integerValue, $0[1].textValue) }
    }
    #expect(perGroup.map(\.0) == [0, 1, 2])
    #expect(perGroup.allSatisfy { $0.1?.isEmpty == false })
  }

  @Test
  func aggregatesOverNoRowsStillFinish() async throws {
    var configuration = SQLiteConfiguration.default
    register(&configuration, longest: true)
    let database = try inMemoryDatabase(configuration: configuration)
    try await seedNotes(database, lengths: [1])

    // With no rows to step through, SQLite calls only the finalizer, which has to create the
    // aggregation state it would otherwise have found.
    let longest = try await database.read { transaction in
      try transaction.fetchOne("SELECT longest(title) FROM notes WHERE 0") { $0[0] }
    }
    #expect(longest == .null)
  }

  #if canImport(Darwin) || os(Linux) || os(Android)
    @Test
    func extensionsComposeWithTheCrossProcessConfiguration() async throws {
      try await withTestDatabaseFile("fn") { file in
        // Function registration composes with the native cross-process defaults.
        var configuration = SQLiteConfiguration.default
        register(&configuration, repeated: true)

        let database = try file.ipcDatabase(configuration: configuration)
        try await seedNotes(database, lengths: [2])

        let repeatedTitle = try await database.fetchOne(
          sql: "SELECT repeated(title, 2) FROM notes",
          as: String.self
        )
        #expect(repeatedTitle == "xxxx")

        // The native defaults must have survived registration.
        let trustedSchema = try await database.fetchOne(sql: "PRAGMA trusted_schema", as: Int.self)
        #expect(trustedSchema == 0)
      }
    }
  #endif

  @Test
  func manyConcurrentAggregatesMakeProgress() async throws {
    var configuration = SQLiteConfiguration.default
    register(&configuration, longest: true)

    try await withPooledDatabase(configuration: configuration, readerCount: 16) { database in
      try await seedNotes(database, lengths: (1...2000).map { $0 % 40 + 1 })

      // Every aggregation runs on the reader thread SQLite called it from, and keeps its rows in
      // its own aggregate context. Run many at once to hold that separation down.
      let lengths = try await concurrentReads(128, of: database) { transaction in
        try transaction.fetchOne("SELECT longest(title) FROM notes", as: String.self)?.count
      }
      #expect(lengths.count == 128)
      #expect(lengths.allSatisfy { $0 == 40 })
    }
  }

  @Test(.libraryHooks)
  func functionCallbacksRunThroughTheSuppliedTableRatherThanTheLinkedBuild() async throws {
    // A function's callbacks read arguments and write results through the build that called
    // them, which is the whole reason a table has to carry them. Interposing those entry points
    // is the only way to observe that the callback used this table rather than the linked SQLite.
    let userData = Lock(0)
    let readArguments = Lock(0)
    let writtenResults = Lock(0)

    var configuration = SQLiteConfiguration.default
    configuration.library.scalarFunctions!.callbacks.context.userData = LibraryHooks.userData {
      context in
      userData.withLock { $0 += 1 }
      return builtInTestLibrary.scalarFunctions!.callbacks.context.userData(context)
    }
    configuration.library.scalarFunctions!.callbacks.argument.text = LibraryHooks.argumentText {
      value in
      readArguments.withLock { $0 += 1 }
      return builtInTestLibrary.scalarFunctions!.callbacks.argument.text(value)
    }
    configuration.library.scalarFunctions!.callbacks.result.text = LibraryHooks.resultText {
      context,
      text,
      count in
      writtenResults.withLock { $0 += 1 }
      builtInTestLibrary.scalarFunctions!.callbacks.result.text(context, text, count)
    }
    register(&configuration, repeated: true)

    let driver = try SQLiteQueue(path: ":memory:", configuration: configuration)
    let value = try await driver.fetchOne(sql: "SELECT repeated('ab', 2)", as: String.self)

    #expect(value == "abab")
    #expect(userData.withLock { $0 } == 1)
    #expect(readArguments.withLock { $0 } == 1)
    #expect(writtenResults.withLock { $0 } == 1)
  }

  @Test(.libraryHooks)
  func aggregateCallbacksRunThroughTheSuppliedTableRatherThanTheLinkedBuild() async throws {
    let aggregateContexts = Lock(0)
    var configuration = SQLiteConfiguration.default
    configuration.library.aggregateFunctions!.context = LibraryHooks.aggregateContext {
      context,
      size in
      aggregateContexts.withLock { $0 += 1 }
      return builtInTestLibrary.aggregateFunctions!.context(context, size)
    }
    register(&configuration, longest: true)

    let driver = try SQLiteQueue(path: ":memory:", configuration: configuration)
    let longest = try await driver.fetchOne(
      sql: "SELECT longest(x) FROM (SELECT 'ab' AS x UNION SELECT 'abcd')",
      as: String.self
    )

    #expect(longest == "abcd")
    // Two steps and one finalizer, each reaching for the same per-invocation slot.
    #expect(aggregateContexts.withLock { $0 } == 3)
  }

  @Test
  func functionsAreAvailableToConnectionSetupSQL() async throws {
    var configuration = SQLiteConfiguration.default
    register(&configuration, repeated: true)
    configuration.setups.append(contentsOf: [
      .sql("CREATE TABLE configured (value TEXT NOT NULL)"),
      .sql("INSERT INTO configured VALUES (repeated('ab', 2))")
    ])
    let driver = try SQLiteQueue(path: ":memory:", configuration: configuration)

    let values = try await driver.fetchAll(sql: "SELECT value FROM configured", as: String.self)
    #expect(values == ["abab"])
  }

  private struct FunctionFailure: Error {}

  private struct LongestText: SQLiteAggregateAccumulator {
    var longest: String?

    mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
      guard let text = arguments[0].textValue else { return }
      if text.count > longest?.count ?? -1 { longest = text }
    }

    func finish() throws -> OrbitDatabaseValue {
      longest.map(OrbitDatabaseValue.text) ?? nil
    }
  }

  private struct FailingAccumulator: SQLiteAggregateAccumulator {
    let failsInStep: Bool

    mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
      if failsInStep { throw FunctionFailure() }
    }

    func finish() throws -> OrbitDatabaseValue {
      throw FunctionFailure()
    }
  }

  // MARK: - Structured Queries functions

  // The functions Structured Queries declares are registered through an adapter that decodes
  // their arguments with `SQLiteFunctionDecoder`, which is what these are about.
  #if StructuredQueries
    @DatabaseFunction(isDeterministic: true)
    func repeatedTitle(_ text: String, _ count: Int) -> String {
      String(repeating: text, count: count)
    }

    @DatabaseFunction
    func longestTitle(_ titles: some Sequence<String>) -> String? {
      titles.max(by: { $0.count < $1.count })
    }

    @DatabaseFunction
    func titleCount(_ ids: some Sequence<Int>) -> Int {
      ids.reduce(0) { total, _ in total + 1 }
    }

    @DatabaseFunction
    func describe(
      _ double: Double,
      _ blob: [UInt8],
      _ flag: Bool,
      _ date: Date,
      _ id: UUID,
      _ missing: Int?
    ) -> String {
      "\(double) \(blob) \(flag) \(date.timeIntervalSince1970) \(id.uuidString) \(missing ?? -1)"
    }

    private struct VariadicSumFunction: ScalarDatabaseFunction {
      typealias Input = Int
      typealias Output = Int
      var name: String { "variadicSum" }
      var argumentCount: Int? { nil }
      var isDeterministic: Bool { true }
      func invoke(_ decoder: inout some QueryDecoder) throws -> QueryBinding {
        // Always asks for two arguments, however many the call actually supplied.
        let lhs = try decoder.decode(Int.self) ?? 0
        let rhs = try decoder.decode(Int.self) ?? 0
        return .int(Int64(lhs + rhs))
      }
    }

    @Test
    func structuredQueriesFunctionsDecodeTheirArguments() async throws {
      var configuration = SQLiteConfiguration.default
      configuration.register(function: $repeatedTitle)
      configuration.register(function: $longestTitle)
      configuration.register(function: $titleCount)
      configuration.register(function: $describe)
      configuration.register(function: VariadicSumFunction())
      let database = try inMemoryDatabase(configuration: configuration)
      try await seedNotes(database, lengths: [2, 4, 3])
      let id = UUID()
      let date = Date(timeIntervalSince1970: 1_700_000_000.5)

      let (described, longest, count) = try await database.read { transaction in
        (
          [
            try Select($describe(1.5, [1, 2, 3], true, date, id, Int?.none)).fetchOne(transaction),
            // A zero-length blob has no buffer behind it, and must still decode.
            try Select($describe(-0.25, [], false, date, id, Int?.some(7))).fetchOne(transaction)
          ],
          try transaction.fetchOne("SELECT longestTitle(title) FROM notes", as: String.self),
          // An aggregate over no rows still runs its body.
          try transaction.fetchOne("SELECT titleCount(id) FROM notes WHERE 0", as: Int.self)
        )
      }
      #expect(
        described == [
          "1.5 [1, 2, 3] true 1700000000.5 \(id.uuidString) -1",
          "-0.25 [] false 1700000000.5 \(id.uuidString) 7"
        ]
      )
      #expect(longest == "xxxx")
      #expect(count == 0)

      // An argument that does not decode fails before the body runs, on both the scalar path and
      // the aggregate's per-row step.
      for sql in ["SELECT repeatedTitle('x', 'y')", "SELECT titleCount(title) FROM notes"] {
        await #expect(throws: SQLiteError.self) {
          try await database.fetchOne(sql: sql, as: String.self)
        }
      }

      // A function asking for an argument it was not given reports it.
      #expect(try await database.fetchOne(sql: "SELECT variadicSum(2, 3)", as: Int.self) == 5)
      let missingArgument = await #expect(throws: SQLiteError.self) {
        try await database.fetchOne(sql: "SELECT variadicSum(2)", as: Int.self)
      }
      #expect(missingArgument?.message?.contains("without an argument at index 1") == true)
    }

    @Test
    func structuredQueriesRegistrationsWorkOnAnOpenConnection() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withConnectionAccess { connection in
        try connection.register(function: $repeatedTitle)
        try connection.register(function: $longestTitle)
        try connection.register(collation: $characterCount)
      }
      let (repeated, longest, sorted) = try owner.withReadConnection { connection in
        (
          try connection.fetchOne("SELECT repeatedTitle('ab', 2)", as: String.self),
          try connection.fetchOne(
            "SELECT longestTitle(column1) FROM (VALUES ('a'), ('abcd'))",
            as: String.self
          ),
          try connection.fetchAll(
            "SELECT column1 FROM (VALUES ('ab'), ('é')) ORDER BY column1 COLLATE characterCount",
            as: String.self
          )
        )
      }
      #expect(repeated == "abab")
      #expect(longest == "abcd")
      #expect(sorted == ["é", "ab"])
    }
  #endif
#endif
