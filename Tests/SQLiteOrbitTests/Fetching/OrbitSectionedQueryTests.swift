#if StructuredQueries && BuiltInSQLite
  import SQLiteOrbit
  import StructuredQueriesSQLite
  import Testing

  @Suite
  struct OrbitSectionedQueryTests {
    @Test
    func typedKeysPreserveOrderingBindingsLimitsAndRequestIdentity() throws {
      let database = try sectionDatabase()
      let minimumID = 0
      let statement = Item.where { $0.id.gt(minimumID) }.order(by: \.title)
      let request = statement.sectioned(by: \.bucket)
      #expect(request == statement.sectioned { $0.bucket })
      #expect(Set([request, statement.sectioned(by: \.bucket)]).count == 1)
      #expect(request.sql.bindings == [0])
      let sections = try database.readBlocking { try request.fetch($0) }
      #expect(sections.sectionNames == [nil, 1, 2])
      #expect(sections.elements.map(\.id) == [2, 4, 3, 1])
      #expect(sections[sectionName: 2]?.map(\.title) == ["A", "C"])
      let limited = try database.readBlocking {
        try statement.limit(3).sectioned { $0.bucket.desc(nulls: .last) }.fetch($0)
      }
      #expect(limited.sectionNames == [2, 1])
      #expect(limited.elements.map(\.id) == [3, 1, 4])
      let offset = 10
      let expression = Item.all.sectioned { $0.id + offset }
      #expect(expression.sql.bindings == [10, 10])
      let computed = try database.readBlocking { try expression.fetch($0) }
      #expect(computed.sectionNames == [11, 12, 13, 14])
      let empty = try database.readBlocking {
        try Item.where { $0.id.lt(0) }.sectioned(by: \.bucket).fetch($0)
      }
      #expect(empty.isEmpty)
    }

    @Test
    func projectionsAndJoinsCanGroupByUnselectedColumns() throws {
      let database = try sectionDatabase()
      let statement = Item.join(Team.all) { $0.teamID.eq($1.id) }
        .order { item, _ in item.title }
        .select { item, _ in item.title }
      let joined = statement.sectioned { _, team in team.id }
      let from = statement.sectioned(by: \.bucket)
      let selected = Item.order(by: \.title).select(\.title).sectioned(by: \.bucket)
      let (byTeam, byBucket, titles) = try database.readBlocking {
        (try joined.fetch($0), try from.fetch($0), try selected.fetch($0))
      }
      #expect(byTeam.sectionNames == [1, 2])
      #expect(byTeam.elements == ["C", "D", "A", "B"])
      #expect(byBucket.sectionNames == [nil, 1, 2])
      #expect(byBucket == titles)
      let multipleJoins = Item.join(Team.all) { $0.teamID.eq($1.id) }
        .join(Team.as(OtherTeam.self).all) { item, _, team in item.teamID.eq(team.id) }
        .order { item, _, _ in item.title }
        .select { item, _, _ in item.title }
        .sectioned { _, _, team in team.id }
      let byOtherTeam = try database.readBlocking { try multipleJoins.fetch($0) }
      #expect(byOtherTeam == byTeam)
      try database.writeBlocking { try $0.execute("UPDATE section_items SET title = 'same'") }
      let distinct = Item.select(\.title).distinct().sectioned(by: \.bucket)
      let groupedDistinct = try database.readBlocking { try distinct.fetch($0) }
      #expect(groupedDistinct.sectionNames == [nil, 1, 2])
      #expect(groupedDistinct.elements == ["same", "same", "same"])
    }

    @Test
    func typedRawStatementsKeepTheirOwnOrderAndReportDecodingErrors() throws {
      let database = try sectionDatabase()
      let request = OrbitSectionedQuery(
        #sql(
          "SELECT title, bucket FROM section_items ORDER BY id",
          as: (String, Int?).self
        )
      )
      let sections = try database.writeBlocking { try request.fetch($0) }
      #expect(sections.elements == ["C", "B", "A", "D"])
      #expect(sections.sectionNames == [2, nil, 1])
      #expect(sections[sectionName: 2]?.map { $0 } == ["C", "A"])
      let invalid = OrbitSectionedQuery(
        #sql("SELECT 'title', 'invalid integer'", as: (String, Int).self)
      )
      #expect(throws: (any Error).self) { try database.readBlocking { try invalid.fetch($0) } }
    }

    @Test
    func theSameRequestSupportsObservationAndFetch() async throws {
      let database = try sectionDatabase()
      let request = Item.order(by: \.title).sectioned(by: \.bucket)
      let received = TestRecorder<OrbitFetchSectionCollection<Item, Int?>>()
      let subscription = try OrbitValueObservation.tracking { try request.fetch($0) }
        .subscribe(
          to: database,
          scheduling: .immediate,
          onError: { Issue.record($0) },
          onChange: {
            received.append($0.value)
          }
        )
      defer { subscription.cancel() }
      @Fetch(request, database: database) var sections = OrbitFetchSectionCollection<Item, Int?>()
      #expect(sections.sectionNames == [nil, 1, 2])
      #expect(received.values.last == sections)
      try await database.write {
        try $0.execute("UPDATE section_items SET bucket = 3 WHERE id = 3")
      }
      try await waitUntil {
        sections.sectionNames == [nil, 1, 2, 3]
          && received.values.last?.sectionNames == [nil, 1, 2, 3]
      }
      #expect(sections[sectionName: 3]?.map(\.id) == [3])
    }

    private func sectionDatabase() throws -> SQLiteQueue {
      let database = try SQLiteQueue(path: ":memory:", configuration: .default)
      try database.writeBlocking { transaction in
        try transaction.executeScript(
          """
          CREATE TABLE section_items (id INTEGER PRIMARY KEY, bucket INTEGER, title TEXT, teamID INTEGER);
          CREATE TABLE section_teams (id INTEGER PRIMARY KEY);
          INSERT INTO section_teams VALUES (1), (2);
          INSERT INTO section_items VALUES (1, 2, 'C', 1), (2, NULL, 'B', 2), (3, 2, 'A', 2), (4, 1, 'D', 1);
          """
        )
      }
      return database
    }

    @Table("section_items")
    struct Item: Equatable, Sendable {
      let id: Int
      var bucket: Int?
      let title: String
      let teamID: Int
    }

    enum OtherTeam: AliasName {}

    @Table("section_teams")
    struct Team: Sendable {
      let id: Int
    }
  }
#endif
