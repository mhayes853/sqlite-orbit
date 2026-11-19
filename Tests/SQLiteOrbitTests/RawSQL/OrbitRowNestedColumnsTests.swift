#if BuiltInSQLite
  import Testing

  // Use the public import: generated witnesses must be accessible to library clients.
  import SQLiteOrbit

  @Suite
  struct OrbitRowNestedColumnsTests {
    @Test
    func joinDecodesIntoTheRowTypesOfItsTables() async throws {
      let database = try await joinDatabase()
      let rows = try await database.read {
        try $0.fetchAll(
          """
          SELECT r.id, r.title, l.id AS list_id, l.name AS list_name
          FROM reminders r JOIN lists l ON l.id = r.list_id ORDER BY r.id
          """,
          as: ReminderWithList.self
        )
      }
      #expect(
        rows == [
          ReminderWithList(
            reminder: Reminder(id: 1, title: "Milk"),
            list: RemindersList(id: 10, name: "Groceries")
          ),
          ReminderWithList(
            reminder: Reminder(id: 2, title: "Tea"),
            list: RemindersList(id: 10, name: "Groceries")
          )
        ]
      )
    }

    @Test
    func optionalNestedRowIsNilWhenALeftJoinMatchesNothing() async throws {
      let database = try await joinDatabase()
      let rows = try await database.read {
        try $0.fetchAll(
          """
          SELECT r.id AS r_id, r.title AS r_title, l.id AS list_id, l.name AS list_name,
            (SELECT count(*) FROM reminders) AS total
          FROM reminders r LEFT JOIN lists l ON l.id = r.list_id ORDER BY r.id
          """,
          as: ReminderWithOptionalList.self
        )
      }
      #expect(rows.map(\.reminder.id) == [1, 2, 3])
      #expect(rows.map(\.list?.name) == ["Groceries", "Groceries", nil])
      #expect(rows.map(\.total) == [3, 3, 3])
    }

    @Test
    func optionalNestedRowIsPresentWhenAnyColumnHasAValue() async throws {
      let database = try inMemoryDatabase()
      let (partial, empty, unprefixed, unprefixedEmpty) = try await database.read { transaction in
        (
          try transaction.fetchOne("SELECT 1 AS n_id, NULL AS n_note") { row in
            try row[columns: "n_", as: Note?.self]
          },
          try transaction.fetchOne("SELECT NULL AS n_id, NULL AS n_note, 5 AS other") { row in
            try row[columns: "n_", as: Note?.self]
          },
          try transaction.fetchOne("SELECT 1 AS id, NULL AS note") { row in
            try row[columns: "", as: Note?.self]
          },
          try transaction.fetchOne("SELECT NULL AS id, NULL AS note") { row in
            try row[columns: "", as: Note?.self]
          }
        )
      }
      #expect(partial == .some(Note(id: 1, note: nil)))
      #expect(empty == .some(nil))
      #expect(unprefixed == .some(Note(id: 1, note: nil)))
      #expect(unprefixedEmpty == .some(nil))
    }

    @Test
    func nestedRowsNestFurtherAndTheirPrefixesAddUp() async throws {
      let database = try inMemoryDatabase()
      let value = try await database.read {
        try $0.fetchOne(
          """
          SELECT 1 AS a_r_id, 'Milk' AS a_r_title, 10 AS a_list_id, 'Groceries' AS a_list_name,
            3 AS a_total, NULL AS b_r_id, NULL AS b_r_title, NULL AS b_list_id,
            NULL AS b_list_name, NULL AS b_total
          """,
          as: Pair.self
        )
      }
      #expect(value?.first.reminder == Reminder(id: 1, title: "Milk"))
      #expect(value?.first.list == RemindersList(id: 10, name: "Groceries"))
      #expect(value?.first.total == 3)
      #expect(value?.second == nil)
      #expect(Pair.orbitColumnName(for: \Pair.first) == nil)
    }

    @Test
    func nestedRowSeesOnlyItsColumnsUnderTheirUnprefixedNames() async throws {
      let database = try inMemoryDatabase()
      let shape = try await database.read {
        try $0.fetchOne("SELECT 1 AS id, 2 AS p_b, 'x' AS other, 3 AS p_a, 4 AS p_") { row in
          try row[columns: "p_", as: Shape.self]
        }
      }
      #expect(shape == Shape(names: ["b", "a", ""], first: 2, a: 3, hasOther: false))
      // Prefixes match bytes exactly, so a prefix differing in case matches nothing.
      await #expect(throws: OrbitDatabaseColumnDecodingError.self) {
        try await database.read {
          try $0.fetchOne("SELECT 1 AS p_a") { row in try row[columns: "P_", as: Shape.self] }
        }
      }
    }

    @Test
    func failuresAreReportedAgainstTheOuterRowsColumn() async throws {
      let database = try inMemoryDatabase()
      func failure(_ sql: SQL) async -> OrbitDatabaseColumnDecodingError? {
        do {
          _ = try await database.read { try $0.fetchAll(sql, as: Pair.self) }
          return nil
        } catch {
          return error as? OrbitDatabaseColumnDecodingError
        }
      }

      let mistyped = await failure(
        """
        SELECT 1 AS a_r_id, 'Milk' AS a_r_title, 10 AS a_list_id, 7 AS a_list_name, 3 AS a_total,
          NULL AS b_total
        """
      )
      #expect(mistyped?.columnIndex == 3)
      #expect(mistyped?.columnName == "a_list_name")

      let missing = await failure(
        "SELECT 1 AS a_r_id, 'Milk' AS a_r_title, 10 AS a_list_id, 3 AS a_total, NULL AS b_total"
      )
      #expect(missing?.columnIndex == nil)
      #expect(missing?.columnName == "a_list_name")

      // A prefix that no column has throws, even for an optional nested row.
      let unprefixed = await failure(
        "SELECT 1 AS a_r_id, 'Milk' AS a_r_title, NULL AS a_list_id, NULL AS a_list_name, 3 AS a_total"
      )
      #expect(unprefixed?.columnIndex == nil)
      #expect(unprefixed?.columnName == "b_")
    }
  }

  private func joinDatabase() async throws -> SQLiteQueue {
    let database = try inMemoryDatabase()
    try await database.write {
      try $0.executeScript(
        """
        CREATE TABLE lists (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE reminders (id INTEGER PRIMARY KEY, title TEXT NOT NULL, list_id INTEGER);
        INSERT INTO lists VALUES (10, 'Groceries');
        INSERT INTO reminders VALUES (1, 'Milk', 10), (2, 'Tea', 10), (3, 'Call', NULL);
        """
      )
    }
    return database
  }

  @OrbitRow
  private struct Reminder: Equatable, Sendable {
    let id: Int
    let title: String
  }

  @OrbitRow
  private struct RemindersList: Equatable, Sendable {
    let id: Int
    let name: String
  }

  @OrbitRow
  private struct ReminderWithList: Equatable, Sendable {
    @OrbitColumns let reminder: Reminder
    @OrbitColumns(prefix: "list_") let list: RemindersList
  }

  @OrbitRow
  private struct ReminderWithOptionalList: Equatable, Sendable {
    @OrbitColumns(prefix: "r_") let reminder: Reminder
    @OrbitColumns(prefix: "list_") let list: RemindersList?
    let total: Int
  }

  @OrbitRow
  private struct Pair: Equatable, Sendable {
    @OrbitColumns(prefix: "a_") let first: ReminderWithOptionalList
    @OrbitColumns(prefix: "b_") let second: ReminderWithOptionalList?
  }

  @OrbitRow
  private struct Note: Equatable, Sendable {
    let id: Int?
    let note: String?
  }

  private struct Shape: ConvertibleFromOrbitDatabaseRow, Equatable, Sendable {
    var names: [String]
    var first: Int
    var a: Int
    var hasOther: Bool

    init(names: [String], first: Int, a: Int, hasOther: Bool) {
      self.names = names
      self.first = first
      self.a = a
      self.hasOther = hasOther
    }

    init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(
      orbitDatabaseRow row: borrowing Row
    ) throws {
      names = (0..<row.columnCount).map { row.columnName(at: $0) }
      first = try row[0, as: Int.self]
      a = try row[column: "a", as: Int.self]
      hasOther = row.columnIndex(named: "other") != nil || row.columnIndex(named: "id") != nil
    }
  }
#endif
