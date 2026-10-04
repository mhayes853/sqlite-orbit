#if BuiltInSQLite
  import Testing

  // Use the public import: generated witnesses must be accessible to library clients.
  import SQLiteOrbit

  @Suite
  struct OrbitRowMacroIntegrationTests {
    @Test
    func generatedMappingsSupportTypedReadsAndReuseCachedLookup() async throws {
      let names = TestCounter()
      var configuration = SQLiteConfiguration.default
      let name = configuration.library.columns.name
      configuration.library.columns.name = { statement, index in
        names.increment()
        return name(statement, index)
      }
      let database = try inMemoryDatabase(configuration: configuration)
      try await database.read { transaction in
        var cursor = try transaction.rowCursor(
          "SELECT 2 AS priority, 'Milk' AS display_title, 1 AS id UNION ALL SELECT NULL, 'Tea', 2"
        )
        let baseline = names.value
        if let row = try cursor.next() {
          let title: String = try row[column: \Summary.title]
          let priority: Priority? = try row[column: \Summary.priority]
          #expect(title == "Milk")
          #expect(priority == .high)
          #expect(row.columnIndex(for: \Summary.id) == 2)
          #expect(row.columnIndex(for: \Summary.isImportant) == nil)
          #expect(row.columnIndex(named: "display_title") == 1)
          #expect(names.value == baseline + 3)
        } else {
          Issue.record("Expected a first row")
        }
        if let row = try cursor.next() {
          #expect(try row[column: \Summary.title] == "Tea")
          #expect(try row[column: \Summary.priority] == nil)
          #expect(names.value == baseline + 3)
        } else {
          Issue.record("Expected a second row")
        }
      }
    }

    @Test
    func generatedMappingsAllowDuplicateNamesAndMatchUnicodeBytesExactly() async throws {
      let database = try inMemoryDatabase()
      let values = try await database.read { transaction in
        try transaction.fetchOne(
          "SELECT 1 AS same, 2 AS same, 3 AS \(quote: "é"), 4 AS \(quote: "e\u{301}")"
        ) { row in
          (
            try row[column: \MappedNames.first],
            try row[column: \MappedNames.second],
            row.columnIndex(for: \MappedNames.first),
            row.columnIndex(for: \MappedNames.second),
            try row[column: \MappedNames.composed],
            try row[column: \MappedNames.decomposed]
          )
        }
      }
      let result = try #require(values)
      #expect(result.0 == 1)
      #expect(result.1 == 1)
      #expect(result.2 == 0)
      #expect(result.3 == 0)
      #expect(result.4 == 3)
      #expect(result.5 == 4)
    }

    @Test
    func synthesizedValuesDecodeNamedColumnsAndPreserveMemberwiseInitialization() async throws {
      let database = try inMemoryDatabase()
      let expected = Summary(id: 1, title: "Milk", priority: .high)
      let values = try await database.read {
        try $0.fetchAll(
          "SELECT 2 AS priority, 'Milk' AS display_title, 1 AS id, 'extra' AS ignored",
          as: Summary.self
        )
      }
      #expect(values == [expected])
      #expect(values.first?.isImportant == true)
    }

    @Test
    func synthesizedOptionalPropertiesAcceptNullButRequireAColumn() async throws {
      let database = try inMemoryDatabase()
      let value = try await database.read {
        try $0.fetchOne(
          "SELECT 1 AS id, 'Milk' AS display_title, NULL AS priority",
          as: Summary.self
        )
      }
      #expect(value?.priority == nil)
      await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read {
          try $0.fetchAll("SELECT 1 AS id, 'Milk' AS display_title", as: Summary.self)
        }
      }
    }

    @Test
    func genericsNestedTypesObserversAndDeclaredConformanceCompileAndDecode() async throws {
      let database = try inMemoryDatabase()
      let (generic, nested, declared, observed) = try await database.read { transaction in
        (
          try transaction.fetchOne("SELECT 7 AS value", as: Box<Int>.self),
          try transaction.fetchOne(
            "SELECT 'hello' AS \(quote: "a \"quoted\" column")",
            as: Container.Nested.self
          ),
          try transaction.fetchOne("SELECT 9 AS id", as: Declared.self),
          try transaction.fetchOne("SELECT 4 AS id", as: Observed.self)
        )
      }
      #expect(generic?.value == 7)
      #expect(nested?.class == "hello")
      #expect(declared?.id == 9)
      #expect(observed?.id == 4)
      #expect(Box<Int>.orbitColumnName(for: \Box<Int>.value) == "value")
      #expect(
        Container.Nested.orbitColumnName(for: \Container.Nested.`class`) == "a \"quoted\" column"
      )
      #expect(Declared.orbitColumnName(for: \Declared.id) == "id")
      let shadowed = try await database.read {
        try $0.fetchOne("SELECT 5 AS first, 6 AS second", as: ShadowedNames<Int, Int>.self)
      }
      #expect(shadowed?.first == 5)
      #expect(shadowed?.second == 6)
      #expect(
        ShadowedNames<Int, Int>.orbitColumnName(for: \ShadowedNames<Int, Int>.first) == "first"
      )
    }

    @Test
    func generatedInitializerWorksWithReturningAndCursorAlgorithms() async throws {
      let database = try inMemoryDatabase()
      let titles = try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE summaries (id INTEGER, display_title TEXT, priority INTEGER)"
        )
        return
          try transaction.executeCursor(
            "INSERT INTO summaries VALUES (1, 'Milk', NULL), (2, 'Tea', 2) RETURNING *",
            as: Summary.self
          )
          .map(\.title)
          .collect()
      }
      #expect(titles == ["Milk", "Tea"])
    }

    @Test
    func publicWitnessCanInitializePrivateStorageAndQualifiedMacros() async throws {
      let database = try inMemoryDatabase()
      let value = try await database.read {
        try $0.fetchOne("SELECT 8 AS identifier", as: PublicOrbitRowRecord.self)
      }
      #expect(value?.value == 8)
      #expect(PublicOrbitRowRecord.orbitColumnName(for: \PublicOrbitRowRecord.value) == nil)
      let aliased = try await database.read {
        try $0.fetchOne("SELECT 3 AS id", as: Aliased.self)
      }
      #expect(aliased?.id == 3)
    }
  }

  @OrbitRow
  private struct Summary: Equatable, Sendable {
    let id: Int
    @OrbitColumn("display_title") var title: String = ""
    let priority: Priority?
    static let table = "summaries"
    var isImportant: Bool { priority == .high }
  }

  private enum Priority: Int, OrbitDatabaseValueConvertible, Sendable {
    case low, medium, high
  }

  @OrbitRow
  private struct Box<Row: ConvertibleFromOrbitDatabaseValue & Sendable>: Sendable {
    let value: Row
  }

  @OrbitRow
  private struct ShadowedNames<
    String: ConvertibleFromOrbitDatabaseValue & Sendable,
    PartialKeyPath: ConvertibleFromOrbitDatabaseValue & Sendable
  >: Sendable {
    let first: String
    let second: PartialKeyPath
  }

  private enum Container {
    @OrbitRow
    struct Nested: Sendable {
      @OrbitColumn("a \"quoted\" column") let `class`: String
    }
  }

  @OrbitRow
  private struct Declared: ConvertibleFromOrbitDatabaseRow, OrbitDatabaseRowColumns, Sendable {
    let id: Int
  }

  @OrbitRow
  private struct Observed: Sendable {
    var id: Int = 0 {
      didSet {}
    }
  }

  @OrbitRow
  private struct Aliased: Sendable {
    typealias Row = Int
    let id: Row
  }

  @OrbitRow
  private struct MappedNames {
    @OrbitColumn("same") let first: Int
    @OrbitColumn("same") let second: Int
    @OrbitColumn("é") let composed: Int
    @OrbitColumn("e\u{301}") let decomposed: Int
  }

  @SQLiteOrbit.OrbitRow
  public struct PublicOrbitRowRecord: Sendable {
    @SQLiteOrbit.OrbitColumn("identifier") private let id: Int
    public var value: Int { id }
  }
#endif
