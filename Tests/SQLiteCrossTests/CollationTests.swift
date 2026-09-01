#if GRDB
  import Foundation
  import GRDB
  import SQLiteCross
  import Testing

  /// Orders text by its reversed characters, so the result is distinguishable from the default
  /// ordering for any test data.
  @DatabaseCollation
  func reversedText(_ lhs: String, _ rhs: String) -> CollationOrder {
    CollationOrder(String(lhs.reversed()), String(rhs.reversed()))
  }

  extension Collation where Self == NamedCollation {
    fileprivate static var reversedText: Self { Self($reversedText) }
  }

  @Test
  func collationsAreInstalledOnEveryConnectionAPoolOpens() async throws {
    let directory = URL(
      fileURLWithPath: NSTemporaryDirectory(),
      isDirectory: true
    )
    .appendingPathComponent("sqlite-cross-collations-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var extensions = DatabaseExtensions()
    extensions.add(collation: $reversedText)

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
        #sql("CREATE TABLE words (id INTEGER PRIMARY KEY, text TEXT NOT NULL)", as: Void.self)
      )
      try transaction.execute(
        Word.insert {
          Word(id: 1, text: "ab")
          Word(id: 2, text: "ba")
          Word(id: 3, text: "cc")
        }
      )
    }

    let natural = try await database.read { transaction in
      try transaction.fetchAll(Word.order(by: \.text).select(\.text))
    }
    #expect(natural == ["ab", "ba", "cc"])

    // Reversing each key puts "ba" first, which the default collation never would.
    let reversed = try await database.read { transaction in
      try transaction.fetchAll(
        Word.order { $0.text.collate(.reversedText) }.select(\.text)
      )
    }
    #expect(reversed == ["ba", "ab", "cc"])

    // Run enough concurrent reads that the pool must open readers beyond the first. A collation
    // installed on only one connection would fail here with "no such collation sequence".
    try await withThrowingTaskGroup(of: [String].self) { group in
      for _ in 0..<8 {
        group.addTask {
          try await database.read { transaction in
            try transaction.fetchAll(
              Word.order { $0.text.collate(.reversedText) }.select(\.text)
            )
          }
        }
      }
      for try await result in group {
        #expect(result == ["ba", "ab", "cc"])
      }
    }
  }

  @Table("words")
  private struct Word: Equatable, Sendable {
    let id: Int
    var text: String
  }
#endif
