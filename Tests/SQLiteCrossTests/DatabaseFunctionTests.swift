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

  @Test
  func scalarAndAggregateFunctionsRunOnEveryConnectionAPoolOpens() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("sqlite-cross-functions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var extensions = DatabaseExtensions()
    extensions.add(function: $repeated)
    extensions.add(function: $longestTitle)

    var configuration = Configuration()
    configuration.maximumReaderCount = 4
    configuration.register(extensions)

    let pool = try DatabasePool(
      path: directory.appendingPathComponent("db.sqlite").path,
      configuration: configuration
    )
    let database = CrossProcessDatabase(writer: pool)

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

    let aggregate = try await database.read { transaction in
      try transaction.fetchOne(Note.select { $longestTitle($0.title) }) ?? nil
    }
    #expect(aggregate == "abcd")

    // Force the pool past its first reader. A function installed on one connection only would
    // fail here with "no such function".
    try await withThrowingTaskGroup(of: String?.self) { group in
      for _ in 0..<8 {
        group.addTask {
          try await database.read { transaction in
            try transaction.fetchOne(Note.select { $longestTitle($0.title) }) ?? nil
          }
        }
      }
      for try await result in group {
        #expect(result == "abcd")
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
  func extensionsComposeWithTheCrossProcessConfiguration() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
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
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("sqlite-cross-concurrent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var extensions = DatabaseExtensions()
    extensions.add(function: $longestTitle)

    var configuration = Configuration()
    configuration.maximumReaderCount = 16
    configuration.register(extensions)

    let database = CrossProcessDatabase(
      writer: try DatabasePool(
        path: directory.appendingPathComponent("db.sqlite").path,
        configuration: configuration
      )
    )

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

    // Every aggregation runs on the reader thread SQLite called it from, and keeps its rows in its
    // own aggregate context. Run many at once to hold that separation down.
    try await withThrowingTaskGroup(of: Int?.self) { group in
      for _ in 0..<128 {
        group.addTask {
          try await database.read { transaction in
            try transaction.fetchOne(Note.select { $longestTitle($0.title) })??.count
          }
        }
      }
      var completed = 0
      for try await result in group {
        #expect(result == 40)
        completed += 1
      }
      #expect(completed == 128)
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
