#if GRDB
  import Foundation
  import GRDB
  import SQLiteCross
  import Testing

  @DatabaseFunction(isDeterministic: true)
  func repeated(_ text: String, _ count: Int) -> String {
    String(repeating: text, count: count)
  }

  @DatabaseFunction
  func longestTitle(_ titles: some Sequence<String>) -> String? {
    titles.max(by: { $0.count < $1.count })
  }

  @DatabaseFunction
  func rowCount(_ ids: some Sequence<Int>) -> Int {
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

  struct FunctionFailure: Error {}

  // Written out rather than declared with the macro, which does not carry `throws` through for a
  // free function that takes arguments.
  private struct FailingFunction: ScalarDatabaseFunction {
    typealias Input = Int
    typealias Output = Int
    var name: String { "failing" }
    var argumentCount: Int? { 1 }
    var isDeterministic: Bool { false }
    func invoke(_ decoder: inout some QueryDecoder) throws -> QueryBinding {
      _ = try decoder.decode(Int.self)
      throw FunctionFailure()
    }
  }

  private struct FailingTotalFunction: AggregateDatabaseFunction {
    typealias Input = Int
    typealias Output = Int
    var name: String { "failingTotal" }
    var argumentCount: Int? { 1 }
    var isDeterministic: Bool { false }
    func step(_ decoder: inout some QueryDecoder) throws -> Int {
      try decoder.decode(Int.self) ?? 0
    }
    func invoke(_ arguments: some Sequence<Int>) throws -> QueryBinding {
      throw FunctionFailure()
    }
  }

  private func seededNotes() async throws -> CrossProcessDatabase<GRDBDatabaseDriver> {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )
    try await database.driver.writer.write { db in
      db.install(function: $repeated)
      db.install(function: $longestTitle)
      db.install(function: $rowCount)
      db.install(function: $describe)
      db.install(function: FailingFunction())
      db.install(function: FailingTotalFunction())
    }
    try await database.write { transaction in
      try transaction.execute(
        #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
      )
      try transaction.execute(
        Note.insert {
          Note(id: 1, title: "ab")
          Note(id: 2, title: "abcd")
          Note(id: 3, title: "abc")
        }
      )
    }
    return database
  }

  @Test
  func scalarAndAggregateFunctionsRunOnEveryConnectionAPoolOpens() async throws {
    var extensions = DatabaseExtensions()
    extensions.add(function: $repeated)
    extensions.add(function: $longestTitle)

    try await withPooledDatabase(extensions: extensions) { database in
      try await database.write { transaction in
        try transaction.execute(
          #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
        )
        try transaction.execute(
          Note.insert {
            Note(id: 1, title: "ab")
            Note(id: 2, title: "abcd")
            Note(id: 3, title: "abc")
          }
        )
      }

      let scalar = try await database.read { transaction in
        try transaction.fetchAll(Note.where { $0.id.eq(1) }.select { $repeated($0.title, 3) })
      }
      #expect(scalar == ["ababab"])

      // Force the pool past its first reader. A function installed on one connection only would
      // fail here with "no such function".
      let aggregates = try await concurrentReads(8, of: database) { transaction in
        try transaction.fetchOne(Note.select { $longestTitle($0.title) }) ?? nil
      }
      #expect(aggregates.allSatisfy { $0 == "abcd" })
    }
  }

  @Test
  func functionArgumentsDecodeEveryStorageClass() async throws {
    let database = try await seededNotes()
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000.5)

    let described = try await database.read { transaction in
      [
        try transaction.fetchOne(Select($describe(1.5, [1, 2, 3], true, date, id, Int?.none))),
        // A zero-length blob has no buffer behind it, and must still decode.
        try transaction.fetchOne(Select($describe(-0.25, [], false, date, id, Int?.some(7)))),
      ]
    }

    #expect(
      described == [
        "1.5 [1, 2, 3] true 1700000000.5 \(id.uuidString) -1",
        "-0.25 [] false 1700000000.5 \(id.uuidString) 7",
      ]
    )
  }

  @Test
  func functionFailuresBecomeStatementErrors() async throws {
    let database = try await seededNotes()

    // The body threw.
    let scalar = await #expect(throws: DatabaseError.self) {
      try await database.read { transaction in
        try transaction.fetchOne(#sql("SELECT failing(1)", as: Int.self))
      }
    }
    #expect(scalar?.message?.contains("FunctionFailure") == true)

    let aggregate = await #expect(throws: DatabaseError.self) {
      try await database.read { transaction in
        try transaction.fetchOne(#sql("SELECT failingTotal(id) FROM notes", as: Int.self))
      }
    }
    #expect(aggregate?.message?.contains("FunctionFailure") == true)

    // An argument that does not decode fails before the body runs, on both the scalar path and
    // the aggregate's per-row step.
    await #expect(throws: DatabaseError.self) {
      try await database.read { transaction in
        try transaction.fetchOne(#sql("SELECT \(quote: "repeated")('x', 'y')", as: String.self))
      }
    }
    await #expect(throws: DatabaseError.self) {
      try await database.read { transaction in
        try transaction.fetchOne(
          #sql("SELECT \(quote: "rowCount")(\(Note.columns.title)) FROM \(Note.self)", as: Int.self)
        )
      }
    }
  }

  @Test
  func aggregatesSpanManyRowsAndManyGroups() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )
    try await database.driver.writer.write { db in
      db.install(function: $longestTitle)
    }

    try await database.write { transaction in
      try transaction.execute(
        #sql(
          """
          CREATE TABLE samples (
            id INTEGER PRIMARY KEY,
            bucket INTEGER NOT NULL,
            title TEXT NOT NULL
          )
          """,
          as: Void.self
        )
      )
      // A large group, so the aggregation holds many rows before its body runs.
      try transaction.execute(
        Sample.insert {
          for index in 1...500 {
            Sample(
              id: index,
              bucket: index % 3,
              title: String(repeating: "x", count: index % 40 + 1)
            )
          }
        }
      )
    }

    let longest = try await database.read { transaction in
      try transaction.fetchOne(Sample.select { $longestTitle($0.title) }) ?? nil
    }
    #expect(longest?.count == 40)

    // A separate aggregation per group exercises SQLite's per-aggregation context slot.
    let perGroup: [(Int, String?)] = try await database.read { transaction in
      try transaction.fetchAll(
        Sample
          .group(by: \.bucket)
          .order(by: \.bucket)
          .select { ($0.bucket, $longestTitle($0.title)) }
      )
    }
    #expect(perGroup.map(\.0) == [0, 1, 2])
    #expect(perGroup.allSatisfy { $0.1?.isEmpty == false })
  }

  @Test
  func aggregatesOverNoRowsStillRunTheirBody() async throws {
    let database = try await seededNotes()

    // With no rows to step through, SQLite calls only the finalizer, which has to create the
    // aggregation state it would otherwise have found.
    let count = try await database.read { transaction in
      try transaction.fetchOne(Note.where { $0.id.eq(-1) }.select { $rowCount($0.id) })
    }
    #expect(count == 0)

    let longest = try await database.read { transaction in
      try transaction.fetchOne(Note.where { $0.id.eq(-1) }.select { $longestTitle($0.title) })
    }
    #expect(longest == .some(nil))
  }

  @Test
  func extensionsComposeWithTheCrossProcessConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sqlite-cross-compose-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var extensions = DatabaseExtensions()
    extensions.add(function: $repeated)

    // GRDB appends connection setup rather than replacing it, so registering extensions keeps
    // whatever `.crossProcess` already set up.
    var configuration = GRDB.Configuration.crossProcess
    configuration.register(extensions)

    let database = try CrossProcessDatabase(
      path: directory.appendingPathComponent("db.sqlite").path,
      configuration: configuration,
      coordination: .init(directory: directory, backPressure: .fail)
    )

    try await database.write { transaction in
      try transaction.execute(
        #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
      )
      try transaction.execute(Note.insert { Note(id: 1, title: "ab") })
    }

    let repeatedTitle = try await database.read { transaction in
      try transaction.fetchOne(Note.select { $repeated($0.title, 2) })
    }
    #expect(repeatedTitle == "abab")

    // `.crossProcess` sets its own connection setup; it must have survived registration.
    let trustedSchema = try await database.read { transaction in
      try transaction.fetchOne(#sql("PRAGMA trusted_schema", as: Int.self))
    }
    #expect(trustedSchema == 0)
  }

  @Test
  func manyConcurrentAggregatesMakeProgress() async throws {
    var extensions = DatabaseExtensions()
    extensions.add(function: $longestTitle)

    try await withPooledDatabase(extensions: extensions, maximumReaderCount: 16) { database in
      try await database.write { transaction in
        try transaction.execute(
          #sql("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", as: Void.self)
        )
        try transaction.execute(
          Note.insert {
            for index in 1...2000 {
              Note(id: index, title: String(repeating: "x", count: index % 40 + 1))
            }
          }
        )
      }

      // Every aggregation runs on the reader thread SQLite called it from, and keeps its rows in
      // its own aggregate context. Run many at once to hold that separation down.
      let lengths = try await concurrentReads(128, of: database) { transaction in
        try transaction.fetchOne(Note.select { $longestTitle($0.title) })??.count
      }
      #expect(lengths.count == 128)
      #expect(lengths.allSatisfy { $0 == 40 })
    }
  }

  @Table("samples")
  private struct Sample: Equatable, Sendable {
    let id: Int
    var bucket: Int
    var title: String
  }

  @Table("notes")
  private struct Note: Equatable, Sendable {
    let id: Int
    var title: String
  }
#endif
