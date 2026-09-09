#if BuiltInSQLite
  @testable import SQLiteOrbit
  import Testing

  @DatabaseCollation
  func reversedText(_ lhs: String, _ rhs: String) -> CollationOrder {
    CollationOrder(String(lhs.reversed()), String(rhs.reversed()))
  }

  extension Collation where Self == NamedCollation {
    fileprivate static var reversedText: Self { Self($reversedText) }
  }

  @Test
  func collationsAreInstalledOnEveryConnectionAPoolOpens() async throws {
    var configuration = SQLiteConfiguration.default
    configuration.register(collation: $reversedText)

    try await withPooledDatabase(configuration: configuration) { database in
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

  @DatabaseCollation
  func characterCount(_ lhs: String, _ rhs: String) -> CollationOrder {
    CollationOrder(lhs.count, rhs.count)
  }

  @Test
  func collationsCompareTextAsUnicode() async throws {
    var configuration = SQLiteConfiguration.default
    configuration.register(collation: $characterCount)
    let database = OrbitDatabase(
      writer: try SQLiteQueue(path: ":memory:", configuration: configuration)
    )

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

  @Test
  func collationsAreRegisteredThroughTheSuppliedTable() async throws {
    // A comparator is handed its user data directly, so a collation needs nothing from the build
    // that called it. Registration is the one part that goes through the table.
    let registrations = Lock(0)
    var configuration = SQLiteConfiguration.default
    configuration.library.create_collation_v2 = { connection, name, flags, box, compare, destroy in
      registrations.withLock { $0 += 1 }
      return builtInTestLibrary.create_collation_v2(
        connection,
        name,
        flags,
        box,
        compare,
        destroy
      )
    }
    configuration.register(collation: $reversedText)

    let driver = try SQLiteQueue(path: ":memory:", configuration: configuration)
    let ordered = try await driver.read { transaction in
      try transaction.fetchAll(
        #sql(
          """
          SELECT text FROM (SELECT 'ab' AS text UNION SELECT 'ba')
          ORDER BY text COLLATE reversedText
          """,
          as: String.self
        )
      )
    }

    #expect(ordered == ["ba", "ab"])
    #expect(registrations.withLock { $0 } == 1)
  }
#endif
