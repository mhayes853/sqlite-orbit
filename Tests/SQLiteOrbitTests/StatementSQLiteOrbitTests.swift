#if BuiltInSQLite
  import SQLiteOrbit
  import Testing

  @Test
  func statementsSupportSQLiteDataStyleExecutionAndFetching() async throws {
    let database = try SQLiteQueue(path: ":memory:")

    let updatedQuantity = try await database.write { transaction in
      try #sql(
        """
        CREATE TABLE query_first_items (
          id INTEGER PRIMARY KEY,
          quantity INTEGER NOT NULL
        )
        """
      )
      .execute(transaction)
      try #sql(
        """
        CREATE TABLE query_first_labels (
          id INTEGER PRIMARY KEY,
          item_id INTEGER NOT NULL,
          name TEXT NOT NULL
        )
        """
      )
      .execute(transaction)
      try QueryFirstItem.insert { QueryFirstItem(id: 1, quantity: 2) }.execute(transaction)
      try QueryFirstLabel.insert {
        QueryFirstLabel(id: 10, itemID: 1, name: "primary")
      }
      .execute(transaction)
      return try QueryFirstItem.update { $0.quantity += 1 }
        .returning(\.quantity)
        .fetchOne(transaction)
    }
    #expect(updatedQuantity == 3)

    let snapshot = try await database.read { transaction in
      let items = try QueryFirstItem.all.fetchAll(transaction)
      let quantity = try QueryFirstItem.select(\.quantity).fetchOne(transaction)
      let tuple = try QueryFirstItem.select { ($0.id, $0.quantity) }.fetchOne(transaction)
      let count = try QueryFirstItem.all.fetchCount(transaction)
      let found = try QueryFirstItem.all.find(transaction, key: 1)
      let raw = try #sql(
        "SELECT quantity FROM query_first_items WHERE id = 1",
        as: Int.self
      )
      .fetchOne(transaction)
      let rawTuple = try #sql(
        "SELECT id, quantity FROM query_first_items WHERE id = 1",
        as: (Int, Int).self
      )
      .fetchOne(transaction)
      let joined =
        try QueryFirstItem
        .join(QueryFirstLabel.all) { $0.id.eq($1.itemID) }
        .fetchOne(transaction)

      var cursor = try QueryFirstItem.select(\.quantity).fetchCursor(transaction)
      let cursorValue = try cursor.next()
      return (items, quantity, tuple, count, found, raw, rawTuple, joined, cursorValue)
    }

    #expect(snapshot.0 == [QueryFirstItem(id: 1, quantity: 3)])
    #expect(snapshot.1 == 3)
    #expect(snapshot.2?.0 == 1)
    #expect(snapshot.2?.1 == 3)
    #expect(snapshot.3 == 1)
    #expect(snapshot.4 == QueryFirstItem(id: 1, quantity: 3))
    #expect(snapshot.5 == 3)
    #expect(snapshot.6?.0 == 1)
    #expect(snapshot.6?.1 == 3)
    #expect(snapshot.7?.0 == QueryFirstItem(id: 1, quantity: 3))
    #expect(snapshot.7?.1 == QueryFirstLabel(id: 10, itemID: 1, name: "primary"))
    #expect(snapshot.8 == 3)

    try await database.writeWithoutTransaction { connection in
      try QueryFirstItem.insert { QueryFirstItem(id: 2, quantity: 4) }.execute(connection)
      try #sql("UPDATE query_first_items SET quantity = 5 WHERE id = 2").execute(connection)
    }
    let count = try await database.read { try QueryFirstItem.all.fetchCount($0) }
    #expect(count == 2)
  }

  @Test
  func rawSQLExecuteInReadAccessIsStillReadOnly() async throws {
    let database = try SQLiteQueue(path: ":memory:")
    try await database.write { transaction in
      try #sql(
        "CREATE TABLE query_first_items (id INTEGER PRIMARY KEY, quantity INTEGER NOT NULL)"
      )
      .execute(transaction)
      try QueryFirstItem.insert { QueryFirstItem(id: 1, quantity: 2) }.execute(transaction)
    }

    // A structured mutation does not compile here because its `execute` overload requires an
    // `OrbitDatabaseWriteTransaction`:
    // try QueryFirstItem.update { $0.quantity += 1 }.execute(transaction)
    let error = await #expect(throws: SQLiteError.self) {
      try await database.read { transaction in
        try #sql(
          "UPDATE query_first_items SET quantity = quantity + 1"
        )
        .execute(transaction)
      }
    }
    #expect(error?.primaryCode == .readOnly)

    let quantity = try await database.read {
      try QueryFirstItem.select(\.quantity).fetchOne($0)
    }
    #expect(quantity == 2)
  }

  @Table("query_first_items")
  private struct QueryFirstItem: Equatable, Sendable {
    let id: Int
    var quantity: Int
  }

  @Table("query_first_labels")
  private struct QueryFirstLabel: Equatable, Sendable {
    let id: Int
    @Column("item_id") let itemID: Int
    var name: String
  }
#endif
