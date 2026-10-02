#if BuiltInSQLite
  import SQLiteOrbit
  import Testing

  @Suite
  struct OrbitRowPersistenceIntegrationTests {
    @Test
    func generatedIdentityKeepsIdentifiableAndRespectsColumnOverrides() async throws {
      let database = try inMemoryDatabase()
      let record = try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE reminders (record_id INTEGER PRIMARY KEY, title TEXT NOT NULL, notes TEXT)"
        )
        return try transaction.insert(Reminder.self) {
          $0.title = "Milk"
          $0.notes = .some(nil)
        }
      }
      let id: Int64 = record.id
      #expect(id == 1)
      #expect(Reminder.orbitPrimaryKeyColumns == ["record_id"])
      #expect(Reminder.orbitColumnName(for: \.computed) == nil)
      var values = OrbitDatabaseRowValues<Reminder>()
      try record.encodeOrbitDatabaseRow(into: &values)
      #expect(values.id == id)
      #expect(values.title == "Milk")
      #expect(values.notes != nil)
      #expect(values.notes! == nil)
    }

    @Test
    func compositeIdentityUpdatesOnlyOneRecordAndSaveInsertsOrUpdates() async throws {
      let database = try inMemoryDatabase()
      let records = try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE memberships (account_id INTEGER, user_id INTEGER, role TEXT, PRIMARY KEY (account_id, user_id))"
        )
        try transaction.save(Membership(account: 1, user: 1, role: "reader"))
        try transaction.save(Membership(account: 1, user: 2, role: "reader"))
        let found = try transaction.update(Membership(account: 1, user: 2, role: "writer"))
        #expect(found)
        try transaction.save(Membership(account: 1, user: 1, role: "admin"))
        return try transaction.fetchAll(
          "SELECT * FROM memberships ORDER BY user_id",
          asRow: Membership.self
        )
      }
      #expect(
        records == [
          Membership(account: 1, user: 1, role: "admin"),
          Membership(account: 1, user: 2, role: "writer")
        ]
      )
    }

    @Test
    func keylessTablesInsertButCannotUpdateOrSave() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute("CREATE TABLE events (value TEXT)")
        let event = try transaction.insert(Event(value: "hello"))
        #expect(event.value == "hello")
        #expect(throws: OrbitDatabaseRowPersistenceError.missingPrimaryKey) {
          try transaction.update(event)
        }
        #expect(throws: OrbitDatabaseRowPersistenceError.missingPrimaryKey) {
          try transaction.save(event)
        }
      }
    }

    @Test
    func nullableIdentitiesAreRejectedForUpdatesAndSaves() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE nullable_records (id INTEGER PRIMARY KEY, title TEXT)"
        )
        let record = NullableRecord(id: nil, title: "Milk")
        #expect(throws: OrbitDatabaseRowPersistenceError.nullPrimaryKey("id")) {
          try transaction.update(record)
        }
        #expect(throws: OrbitDatabaseRowPersistenceError.nullPrimaryKey("id")) {
          try transaction.save(record)
        }
        #expect(
          try transaction.fetchOne("SELECT count(*) FROM nullable_records", as: Int.self) == 0
        )
      }
    }

    @Test
    func ignoredInsertionsAndMissingRequiredValuesReportErrors() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE reminders (record_id INTEGER PRIMARY KEY, title TEXT NOT NULL, notes TEXT)"
        )
        #expect(throws: SQLiteError.self) {
          try transaction.insert(OrbitDatabaseRowValues<Reminder>())
        }
        try transaction.execute(
          """
          CREATE TRIGGER ignore_insert BEFORE INSERT ON reminders
          BEGIN SELECT RAISE(IGNORE); END
          """
        )
        #expect(throws: OrbitDatabaseRowPersistenceError.noInsertedRow) {
          try transaction.insert(Reminder.self) { $0.title = "Ignored" }
        }
      }
    }

    @Test
    func quotedIdentifiersAndGenericDeclaredConformancesCompileAndPersist() async throws {
      let database = try inMemoryDatabase()
      let records = try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE \(quote: "odd \"table") (id INTEGER PRIMARY KEY, \(quote: "class") TEXT)"
        )
        try transaction.execute(
          "CREATE TABLE generic_records (id INTEGER PRIMARY KEY, value INTEGER)"
        )
        let quoted = try transaction.insert(Quoted(id: 1, class: "hello"))
        let generic = try transaction.insert(Generic<Int>(id: 1, value: 42))
        return (quoted, generic)
      }
      #expect(records.0.class == "hello")
      #expect(records.1.value == 42)
    }

    @Test
    func publicPersistenceCanEncodePrivateStorage() async throws {
      let database = try inMemoryDatabase()
      let record = try await database.write { transaction in
        try transaction.execute("CREATE TABLE private_records (id INTEGER PRIMARY KEY, title TEXT)")
        return try transaction.insert(PublicPersistableRecord(id: 8, title: "Private"))
      }
      #expect(record.value == "Private")
    }
  }

  @OrbitRow(table: "reminders")
  private struct Reminder: Identifiable, Equatable, Sendable {
    @OrbitColumn("record_id") let id: Int64
    var title: String
    var notes: String?
    var computed: String { title }
  }

  @OrbitRow(table: "memberships", primaryKey: ["account_id", "user_id"])
  private struct Membership: Equatable, Sendable {
    @OrbitColumn("account_id") let account: Int
    @OrbitColumn("user_id") let user: Int
    var role: String
  }

  @OrbitRow(table: "events", primaryKey: [])
  private struct Event: Sendable {
    var value: String
  }

  @OrbitRow(table: "nullable_records")
  private struct NullableRecord: Sendable {
    let id: Int?
    var title: String
  }

  @OrbitRow(table: "odd \"table")
  private struct Quoted: Sendable {
    let id: Int
    var `class`: String
  }

  @OrbitRow(table: "generic_records")
  private struct Generic<Row: OrbitDatabaseValueConvertible & Sendable>:
    PersistableOrbitDatabaseRow, Sendable
  {
    let id: Int
    var value: Row
  }

  @SQLiteOrbit.OrbitRow(table: "private_records")
  public struct PublicPersistableRecord: Sendable {
    private let id: Int
    private var title: String
    public var value: String { title }

    public init(id: Int, title: String) {
      self.id = id
      self.title = title
    }
  }
#endif
