#if BuiltInSQLite
  #if StructuredQueries
    import StructuredQueriesSQLite
  #endif
  @testable import SQLiteOrbit
  import Testing

  // Orders text by its bytes read back to front, which puts "ba" before "ab" where the default
  // collation never would.
  private func reversedBytes(
    _ lhs: UnsafeRawBufferPointer,
    _ rhs: UnsafeRawBufferPointer
  ) -> SQLiteCollationOrder {
    let lhs = Array(lhs.reversed())
    let rhs = Array(rhs.reversed())
    if lhs == rhs { return .same }
    return lhs.lexicographicallyPrecedes(rhs) ? .ascending : .descending
  }

  @Test
  func collationsAreInstalledOnEveryConnectionAPoolOpens() async throws {
    var configuration = SQLiteConfiguration.default
    configuration.registerCollation("reversedText", reversedBytes)

    try await withPooledDatabase(configuration: configuration) { database in
      try await database.execute(
        sql: """
          CREATE TABLE words (id INTEGER PRIMARY KEY, text TEXT NOT NULL);
          INSERT INTO words (text) VALUES ('ab'), ('ba'), ('cc');
          """
      )

      let natural = try await database.fetchAll(
        sql: "SELECT text FROM words ORDER BY text",
        as: String.self
      )
      #expect(natural == ["ab", "ba", "cc"])

      // Run enough concurrent reads that the pool must open readers beyond the first: a
      // collation installed on only one connection would fail here with "no such collation
      // sequence".
      let reversed = try await concurrentReads(8, of: database) { transaction in
        try transaction.fetchAll(
          "SELECT text FROM words ORDER BY text COLLATE reversedText",
          as: String.self
        )
      }
      #expect(reversed.allSatisfy { $0 == ["ba", "ab", "cc"] })
    }
  }

  @Test(.libraryHooks)
  func collationsAreRegisteredThroughTheSuppliedTable() async throws {
    // A comparator is handed its user data directly, so a collation needs nothing from the build
    // that called it. Registration is the one part that goes through the table.
    let registrations = Lock(0)
    var configuration = SQLiteConfiguration.default
    configuration.library.collations!.create = LibraryHooks.createCollation {
      connection,
      name,
      flags,
      box,
      compare,
      destroy in
      registrations.withLock { $0 += 1 }
      return builtInTestLibrary.collations!.create(connection, name, flags, box, compare, destroy)
    }
    configuration.registerCollation("reversedText", reversedBytes)

    let driver = try SQLiteQueue(path: ":memory:", configuration: configuration)
    let ordered = try await driver.fetchAll(
      sql: """
        SELECT text FROM (SELECT 'ab' AS text UNION SELECT 'ba')
        ORDER BY text COLLATE reversedText
        """,
      as: String.self
    )

    #expect(ordered == ["ba", "ab"])
    #expect(registrations.withLock { $0 } == 1)
  }

  @Test(.libraryHooks)
  func aCollationTheLibraryRefusesIsReleasedRatherThanLeaked() {
    // `sqlite3_create_collation_v2` only calls the destructor of a registration that succeeded,
    // unlike `sqlite3_create_function_v2`, which calls it either way.
    let flag = CollationReleaseFlag()
    openRefusingCollations(CollationReleaseProbe(flag: flag))
    #expect(flag.isSet)
  }

  // Everything the failed registration could still be holding onto is local to this function, so
  // whatever is alive once it returns is alive because SQLite's side of the handshake kept it.
  private func openRefusingCollations(_ probe: CollationReleaseProbe) {
    var configuration = SQLiteConfiguration.default
    configuration.library.collations!.create = LibraryHooks.createCollation { _, _, _, _, _, _ in
      SQLiteResultCode.error.rawValue
    }
    configuration.registerCollation("probe") { _, _ in
      withExtendedLifetime(probe) { .same }
    }

    #expect(throws: (any Error).self) {
      _ = try SQLiteQueue(path: ":memory:", configuration: configuration)
    }
  }

  private final class CollationReleaseFlag: Sendable {
    private let released = Lock(false)
    var isSet: Bool { self.released.withLock { $0 } }
    func set() { self.released.withLock { $0 = true } }
  }

  private final class CollationReleaseProbe: Sendable {
    private let flag: CollationReleaseFlag
    init(flag: CollationReleaseFlag) { self.flag = flag }
    deinit { self.flag.set() }
  }

  // MARK: - Structured Queries collations

  #if StructuredQueries
    @DatabaseCollation
    func characterCount(_ lhs: String, _ rhs: String) -> CollationOrder {
      CollationOrder(lhs.count, rhs.count)
    }

    @Test
    func structuredQueriesCollationsCompareTextAsUnicode() async throws {
      var configuration = SQLiteConfiguration.default
      configuration.register(collation: $characterCount)
      let database = try SQLiteQueue(path: ":memory:", configuration: configuration)
      try await database.execute(
        sql: """
          CREATE TABLE words (id INTEGER PRIMARY KEY, text TEXT NOT NULL);
          INSERT INTO words (text) VALUES ('日本語'), ('ab'), ('é');
          """
      )

      // "日本語" is nine bytes but three characters, and "é" is two bytes but one.
      let byCharacterCount = try await database.fetchAll(
        sql: "SELECT text FROM words ORDER BY text COLLATE characterCount",
        as: String.self
      )
      #expect(byCharacterCount == ["é", "ab", "日本語"])

      // Equal under the collation, so a `WHERE` comparison through it matches both.
      let sameLength = try await database.fetchOne(
        sql: "SELECT count(*) FROM words WHERE text = 'xx' COLLATE characterCount",
        as: Int.self
      )
      #expect(sameLength == 1)
    }
  #endif
#endif
