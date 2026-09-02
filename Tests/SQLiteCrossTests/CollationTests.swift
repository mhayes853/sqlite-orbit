#if GRDB
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
    var extensions = DatabaseExtensions()
    extensions.add(collation: $reversedText)

    try await withPooledDatabase(extensions: extensions) { database in
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

      // Reversing each key puts "ba" first, which the default collation never would. Run enough
      // concurrent reads that the pool must open readers beyond the first: a collation installed
      // on only one connection would fail here with "no such collation sequence".
      let reversed = try await concurrentReads(8, of: database) { transaction in
        try transaction.fetchAll(Word.order { $0.text.collate(.reversedText) }.select(\.text))
      }
      #expect(reversed.allSatisfy { $0 == ["ba", "ab", "cc"] })
    }
  }

  /// Orders text by its length in characters, so multi-byte characters tell whether the bytes
  /// SQLite hands over were decoded as UTF-8 rather than compared byte for byte.
  @DatabaseCollation
  func characterCount(_ lhs: String, _ rhs: String) -> CollationOrder {
    CollationOrder(lhs.count, rhs.count)
  }

  @Test
  func collationsCompareTextAsUnicode() async throws {
    let database = CrossProcessDatabase(
      driver: GRDBDatabaseDriver(writer: try DatabaseQueue())
    )
    try await database.driver.writer.write { db in
      db.install(collation: $characterCount)
    }

    try await database.write { transaction in
      try transaction.execute(
        #sql("CREATE TABLE words (id INTEGER PRIMARY KEY, text TEXT NOT NULL)", as: Void.self)
      )
      try transaction.execute(
        Word.insert {
          Word(id: 1, text: "日本語")
          Word(id: 2, text: "ab")
          Word(id: 3, text: "é")
        }
      )
    }

    // "日本語" is nine bytes but three characters, and "é" is two bytes but one.
    let byCharacterCount = try await database.read { transaction in
      try transaction.fetchAll(
        Word.order { $0.text.collate(NamedCollation($characterCount)) }.select(\.text)
      )
    }
    #expect(byCharacterCount == ["é", "ab", "日本語"])

    // Equal under the collation, so a `WHERE` comparison through it matches both.
    let sameLength = try await database.read { transaction in
      try transaction.fetchCount(
        Word.where { $0.text.collate(NamedCollation($characterCount)).eq("xx") }
      )
    }
    #expect(sameLength == 1)
  }

  @Table("words")
  private struct Word: Equatable, Sendable {
    let id: Int
    var text: String
  }
#endif
