#if BuiltInSQLite
  import Testing

  // Use the public import: generated witnesses must be accessible to library clients.
  import SQLiteOrbit

  @Suite
  struct OrbitRowMacroIntegrationTests {
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

  private enum Container {
    @OrbitRow
    struct Nested: Sendable {
      @OrbitColumn("a \"quoted\" column") let `class`: String
    }
  }

  @OrbitRow
  private struct Declared: ConvertibleFromOrbitDatabaseRow, Sendable {
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

  @SQLiteOrbit.OrbitRow
  public struct PublicOrbitRowRecord: Sendable {
    @SQLiteOrbit.OrbitColumn("identifier") private let id: Int
    public var value: Int { id }
  }
#endif
