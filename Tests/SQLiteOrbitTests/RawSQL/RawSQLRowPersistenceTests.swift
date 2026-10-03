import Testing

@testable import SQLiteOrbit

@Suite
struct OrbitDatabaseRowValuesTests {
  @Test
  func typedGettersDistinguishOmissionNullAndValues() throws {
    var values = OrbitDatabaseRowValues<ValuesRecord>()
    #expect(values.title == nil)
    #expect(values.notes == nil)
    #expect(!values.contains(\.notes))
    values.title = "Milk"
    values.notes = .some(nil)
    #expect(values.title == "Milk")
    #expect(values.notes != nil)
    #expect(values.notes! == nil)
    #expect(values.contains(\.notes))
    #expect(try values.encodedColumns().map(\.value) == [.null, .text("Milk")])
    values.notes = "Tea"
    #expect(values.notes! == "Tea")
    values.notes = nil
    #expect(!values.contains(\.notes))
    try values.set(\.notes, to: nil)
    #expect(values.notes != nil)
    values.unset(\.notes)
    #expect(values.notes == nil)
  }

  @Test
  func gettersPreserveOutboundOnlyValuesAndCopiesHaveIndependentEntries() throws {
    var values = OrbitDatabaseRowValues<ValuesRecord>()
    values.outbound = Outbound(value: 7)
    var copy = values
    copy.outbound = Outbound(value: 9)
    #expect(values.outbound?.value == 7)
    #expect(copy.outbound?.value == 9)
    #expect(try values.encodedColumns().map(\.value) == [.integer(7)])
  }

  @Test
  func deferredErrorsCanBeReadReplacedOrRemovedAndExplicitSetIsAtomic() throws {
    var values = OrbitDatabaseRowValues<ValuesRecord>()
    values.outbound = Outbound(value: -1)
    #expect(values.contains(\.outbound))
    #expect(values.outbound?.value == -1)
    #expect(throws: ConversionFailure.self) { try values.encodedColumns() }
    values.outbound = Outbound(value: 4)
    #expect(throws: ConversionFailure.self) {
      try values.set(\.outbound, to: Outbound(value: -1))
    }
    #expect(values.outbound?.value == 4)
    #expect(try values.encodedColumns().first?.value == .integer(4))
    values.outbound = Outbound(value: -1)
    values.unset(\.outbound)
    #expect(try values.encodedColumns().isEmpty)
  }

  @Test
  func unsupportedPropertiesAndDuplicateMappingsFailAndOrderingIsStable() throws {
    var values = OrbitDatabaseRowValues<ValuesRecord>()
    #expect(throws: OrbitDatabaseRowPersistenceError.unknownColumn) {
      try values.set(\.computed, to: "bad")
    }
    values.computed = "bad"
    #expect(throws: OrbitDatabaseRowPersistenceError.unknownColumn) {
      try values.encodedColumns()
    }
    values.unset(\.computed)
    values.title = "Milk"
    values.alias = "Tea"
    #expect(throws: OrbitDatabaseRowPersistenceError.duplicateColumn("title")) {
      try values.encodedColumns()
    }
    values.unset(\.alias)
    values.notes = "Note"
    #expect(try values.encodedColumns().map(\.name) == ["notes", "title"])
  }

  @Test
  func canonicallyEquivalentColumnNamesRemainDistinct() throws {
    var values = OrbitDatabaseRowValues<UnicodeValuesRecord>()
    values.composed = "First"
    values.decomposed = "Second"
    let columns = try values.encodedColumns()
    #expect(columns.map { Array($0.name.utf8) } == [Array("e\u{301}".utf8), Array("é".utf8)])
    #expect(columns.map(\.value) == [.text("Second"), .text("First")])
  }
}

private struct UnicodeValuesRecord: ConvertibleToOrbitDatabaseRow {
  var composed: String
  var decomposed: String

  static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? {
    switch keyPath {
    case \Self.composed: "é"
    case \Self.decomposed: "e\u{301}"
    default: nil
    }
  }

  func encodeOrbitDatabaseRow(into values: inout OrbitDatabaseRowValues<Self>) throws {
    try values.set(\.composed, to: composed)
    try values.set(\.decomposed, to: decomposed)
  }
}

private enum ConversionFailure: Error { case invalid }

private struct Outbound: ConvertibleToOrbitDatabaseValue {
  let value: Int64
  func orbitDatabaseValue() throws -> OrbitDatabaseValue {
    guard value >= 0 else { throw ConversionFailure.invalid }
    return .integer(value)
  }
}

private struct ValuesRecord: ConvertibleToOrbitDatabaseRow {
  var title: String
  var notes: String?
  var outbound: Outbound
  var alias: String
  var computed: String { title }

  static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? {
    switch keyPath {
    case \Self.title, \Self.alias: "title"
    case \Self.notes: "notes"
    case \Self.outbound: "outbound"
    default: nil
    }
  }

  func encodeOrbitDatabaseRow(into values: inout OrbitDatabaseRowValues<Self>) throws {
    try values.set(\.title, to: title)
    try values.set(\.notes, to: notes)
    try values.set(\.outbound, to: outbound)
  }
}

#if BuiltInSQLite
  @Suite
  struct RawSQLRowPersistenceTests {
    @Test
    func insertionReturnsGeneratedIdentityDefaultsAndExplicitNull() async throws {
      let database = try inMemoryDatabase()
      let (first, second, defaults) = try await database.write { transaction in
        try transaction.execute(recordSchema)
        let first = try transaction.insert(Record.self) { $0.title = "Milk" }
        var values = OrbitDatabaseRowValues<Record>()
        values.title = "Tea"
        try values.set(\.notes, to: nil)
        let second = try transaction.insert(values)
        let defaults = try transaction.insert(OrbitDatabaseRowValues<Record>())
        return (first, second, defaults)
      }
      #expect(first == Record(id: 1, title: "Milk", notes: "default", visits: 3))
      #expect(second == Record(id: 2, title: "Tea", notes: nil, visits: 3))
      #expect(defaults == Record(id: 3, title: "untitled", notes: "default", visits: 3))
    }

    @Test
    func completeRecordsKeepTheirIdentityAndUpdatesSelectColumns() async throws {
      let database = try inMemoryDatabase()
      let result = try await database.write { transaction in
        try transaction.execute(recordSchema)
        let original = Record(id: 42, title: "Milk", notes: nil, visits: 5)
        #expect(try transaction.insert(original) == original)
        let edited = Record(id: 42, title: "Tea", notes: "changed", visits: 8)
        #expect(try transaction.update(edited, columns: [\.title]))
        #expect(try transaction.update(edited, columns: [\.title]))
        let absent = try transaction.update(Record(id: 99, title: "Absent", notes: nil, visits: 0))
        #expect(!absent)
        return try transaction.fetchOne("SELECT * FROM records", asRow: Record.self)
      }
      #expect(result == Record(id: 42, title: "Tea", notes: nil, visits: 5))
    }

    @Test
    func saveAndUpsertHandlePrimaryAndAlternateTargets() async throws {
      let database = try inMemoryDatabase()
      let result = try await database.write { transaction in
        try transaction.execute(recordSchema)
        try transaction.save(Record(id: 1, title: "Milk", notes: nil, visits: 0))
        try transaction.save(Record(id: 1, title: "Tea", notes: "saved", visits: 1))
        try transaction.upsert(
          Record(id: 99, title: "Tea", notes: "alternate", visits: 2),
          onConflict: [\.title],
          updating: [\.notes]
        )
        try transaction.upsert(
          Record(id: 1, title: "ignored", notes: "ignored", visits: 99),
          updating: []
        )
        return try transaction.fetchAll("SELECT * FROM records", asRow: Record.self)
      }
      #expect(result == [Record(id: 1, title: "Tea", notes: "alternate", visits: 1)])
    }

    @Test
    func invalidColumnRequestsFailBeforeAnyWrites() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute(recordSchema)
        let record = Record(id: 1, title: "Milk", notes: nil, visits: 0)
        #expect(throws: OrbitDatabaseRowPersistenceError.identityUpdate("id")) {
          try transaction.update(record, columns: [\.id])
        }
        #expect(throws: OrbitDatabaseRowPersistenceError.duplicateColumn("title")) {
          try transaction.update(record, columns: [\.title, \.title])
        }
        #expect(throws: OrbitDatabaseRowPersistenceError.emptyUpdate) {
          try transaction.update(record, columns: [])
        }
        #expect(throws: OrbitDatabaseRowPersistenceError.unknownColumn) {
          try transaction.update(record, columns: [\.computed])
        }
        #expect(throws: OrbitDatabaseRowPersistenceError.missingPrimaryKey) {
          try transaction.upsert(record, onConflict: [])
        }
        #expect(throws: OrbitDatabaseRowPersistenceError.identityUpdate("title")) {
          try transaction.upsert(record, onConflict: [\.title], updating: [\.title])
        }
        var values = OrbitDatabaseRowValues<Record>()
        values.computed = "bad"
        #expect(throws: OrbitDatabaseRowPersistenceError.unknownColumn) {
          try transaction.insert(values)
        }
        #expect(try transaction.fetchOne("SELECT count(*) FROM records", as: Int.self) == 0)
      }
    }

    @Test
    func constraintAndCustomEncodingFailuresPropagateAndRollBack() async throws {
      let database = try inMemoryDatabase()
      try await database.write { try $0.execute(recordSchema) }
      await #expect(throws: SQLiteError.self) {
        try await database.write { transaction in
          let record = Record(id: 1, title: "Milk", notes: nil, visits: 0)
          try transaction.insert(record)
          try transaction.insert(record)
        }
      }
      #expect(
        try await database.read {
          try $0.fetchOne("SELECT count(*) FROM records", as: Int.self)
        } == 0
      )
      await #expect(throws: ConversionFailure.self) {
        try await database.write { transaction in
          try transaction.insert(Record(id: 1, title: "fail", notes: nil, visits: 0))
        }
      }
    }

    @Test
    func nullableAlternateUniqueTargetsFollowSQLiteConflictSemantics() async throws {
      let database = try inMemoryDatabase()
      let count = try await database.write { transaction in
        try transaction.execute(recordSchema)
        try transaction.execute("CREATE UNIQUE INDEX unique_notes ON records(notes)")
        try transaction.upsert(
          Record(id: 1, title: "Milk", notes: nil, visits: 0),
          onConflict: [\.notes]
        )
        try transaction.upsert(
          Record(id: 2, title: "Tea", notes: nil, visits: 0),
          onConflict: [\.notes]
        )
        return try transaction.fetchOne("SELECT count(*) FROM records", as: Int.self)
      }
      #expect(count == 2)
    }

    @Test
    func missingEncodedIdentitiesFailBeforeExecution() async throws {
      let database = try inMemoryDatabase()
      try await database.write { transaction in
        try transaction.execute(recordSchema)
        let record = IncompleteRecord(id: 1, title: "Milk")
        #expect(throws: OrbitDatabaseRowPersistenceError.missingValue("id")) {
          try transaction.update(record)
        }
        #expect(throws: OrbitDatabaseRowPersistenceError.missingValue("id")) {
          try transaction.save(record)
        }
        #expect(try transaction.fetchOne("SELECT count(*) FROM records", as: Int.self) == 0)
      }
    }
  }

  private let recordSchema: SQL = """
    CREATE TABLE records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL UNIQUE DEFAULT 'untitled',
      notes TEXT DEFAULT 'default',
      visits INTEGER NOT NULL DEFAULT 3
    )
    """

  private struct Record: PersistableOrbitDatabaseRow, Equatable, Sendable {
    let id: Int64
    var title: String
    var notes: String?
    var visits: Int
    var computed: String { title }

    static let orbitTableName = "records"
    static let orbitPrimaryKeyColumns = ["id"]

    static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? {
      switch keyPath {
      case \Self.id: "id"
      case \Self.title: "title"
      case \Self.notes: "notes"
      case \Self.visits: "visits"
      default: nil
      }
    }

    init(id: Int64, title: String, notes: String?, visits: Int) {
      self.id = id
      self.title = title
      self.notes = notes
      self.visits = visits
    }

    init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(
      orbitDatabaseRow row: borrowing Row
    ) throws {
      id = try row[column: "id", as: Int64.self]
      title = try row[column: "title", as: String.self]
      notes = try row[column: "notes", as: String?.self]
      visits = try row[column: "visits", as: Int.self]
    }

    func encodeOrbitDatabaseRow(into values: inout OrbitDatabaseRowValues<Self>) throws {
      guard title != "fail" else { throw ConversionFailure.invalid }
      try values.set(\.id, to: id)
      try values.set(\.title, to: title)
      try values.set(\.notes, to: notes)
      try values.set(\.visits, to: visits)
    }
  }

  // A handwritten encoder may omit columns; identity must still be present for update/save.
  private struct IncompleteRecord: PersistableOrbitDatabaseRow {
    let id: Int64
    var title: String

    static let orbitTableName = "records"
    static let orbitPrimaryKeyColumns = ["id"]

    static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? {
      switch keyPath {
      case \Self.id: "id"
      case \Self.title: "title"
      default: nil
      }
    }

    init(id: Int64, title: String) {
      self.id = id
      self.title = title
    }

    init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(
      orbitDatabaseRow row: borrowing Row
    ) throws {
      id = try row[column: "id", as: Int64.self]
      title = try row[column: "title", as: String.self]
    }

    func encodeOrbitDatabaseRow(into values: inout OrbitDatabaseRowValues<Self>) throws {
      try values.set(\.title, to: title)
    }
  }
#endif
