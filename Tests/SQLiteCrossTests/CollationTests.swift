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

  @Table("words")
  private struct Word: Equatable, Sendable {
    let id: Int
    var text: String
  }
#endif
