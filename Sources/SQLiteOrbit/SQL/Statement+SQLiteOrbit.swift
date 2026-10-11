#if StructuredQueries
  public import StructuredQueriesSQLite

  // Structured Queries statements are run with the statement first, as SQLiteData spells it
  // (`try Reminder.all.fetchAll(transaction)`), so a query body reads the same in both libraries.
  //
  // A statement's capability is read off its position in the Structured Queries protocol
  // hierarchy. A `SELECT`-shaped statement, a `PartialSelectStatement`, only reads, so it runs
  // through `rowCursor` in any transaction. Any other `Statement`, such as an `INSERT`, `UPDATE`,
  // or `DELETE` with a `RETURNING` clause, may write, so it runs through `executeRowCursor` or
  // `execute`, and only a write transaction accepts it. Raw `#sql` reads in a read transaction and
  // may write in a write transaction.
  //
  // Statements come in four shapes, and each needs its own decoding. A statement either projects a
  // single value, projects a tuple of values, or projects nothing at all, in which case its rows
  // decode to its `FROM` table plus whatever tables are joined to it.
  //
  // Swift 6.3 tears down the uninitialized result of a throwing call when a caller binds a
  // nonescapable value a generic function returned to a local, so every cursor here is handed
  // straight to the cursor that decodes it, or to `withOrbitCursor`, and never bound itself.

  // MARK: - Execution

  extension Statement where QueryValue == () {
    /// Executes this statement in a write transaction, discarding any rows it returns.
    ///
    /// Read ``OrbitDatabaseWriteTransaction/changesCount`` afterwards for how many rows it changed.
    ///
    /// ```swift
    /// try await database.write { transaction in
    ///   try Reminder.insert { Reminder.Draft(title: "Buy milk") }.execute(transaction)
    ///   try Reminder.where(\.isCompleted).delete().execute(transaction)
    /// }
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to execute the statement.
    /// - Throws: A ``SQLiteError`` when the statement fails.
    public func execute<Transaction>(
      _ transaction: borrowing Transaction
    ) throws
    where
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable
    {
      try transaction.execute(SQL(fragment: query))
    }

    /// Executes this statement on a write connection outside a transaction.
    ///
    /// Each statement commits on its own. This overload is primarily for work that cannot run in a
    /// transaction, such as `VACUUM` or changing foreign-key enforcement.
    ///
    /// ```swift
    /// try await database.writeWithoutTransaction { connection in
    ///   try Reminder.where(\.isCompleted).delete().execute(connection)
    /// }
    /// ```
    ///
    /// - Parameter connection: The write connection on which to execute the statement.
    /// - Throws: A ``SQLiteError`` when the statement fails, in which case SQLite undoes whatever
    ///   it had changed.
    public func execute(_ connection: borrowing SQLiteWriteConnection) throws {
      try connection.execute(SQL(fragment: query))
    }
  }

  extension PartialSelectStatement where QueryValue == () {
    /// Executes this read statement, discarding any rows it returns.
    ///
    /// Prefer a `fetch` operation when the rows are useful.
    ///
    /// ```swift
    /// try await database.read { transaction in
    ///   try Reminder.where(\.isCompleted).execute(transaction)
    /// }
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to execute the statement.
    /// - Throws: A ``SQLiteError`` when the statement fails.
    public func execute<Transaction>(
      _ transaction: borrowing Transaction
    ) throws
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable
    {
      try withOrbitCursor(try transaction.rowCursor(SQL(fragment: query), cached: false)) {
        cursor in
        while try cursor.next() != nil {}
      }
    }
  }

  extension SQLQueryExpression where QueryValue == () {
    /// Executes this raw SQL in a read transaction, discarding any rows it returns.
    ///
    /// Raw SQL has no statically knowable capability, so a read transaction checks it when it is
    /// prepared and refuses SQL that may write before it runs.
    ///
    /// ```swift
    /// try await database.read { transaction in
    ///   try #sql("PRAGMA optimize").execute(transaction)
    /// }
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to execute the SQL.
    /// - Throws: A ``SQLiteError`` when the statement fails, including one with the code
    ///   ``SQLiteResultCode/readOnly`` when the SQL may write.
    public func execute<Transaction>(
      _ transaction: borrowing Transaction
    ) throws
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable
    {
      try withOrbitCursor(try transaction.rowCursor(SQL(fragment: query), cached: false)) {
        cursor in
        while try cursor.next() != nil {}
      }
    }

    /// Executes this raw SQL in a write transaction, discarding any rows it returns.
    ///
    /// ```swift
    /// try await database.write { transaction in
    ///   try #sql("DELETE FROM reminders WHERE isCompleted").execute(transaction)
    /// }
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to execute the SQL.
    /// - Throws: A ``SQLiteError`` when the statement fails.
    public func execute<Transaction>(
      _ transaction: borrowing Transaction
    ) throws
    where
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable
    {
      try transaction.execute(SQL(fragment: query))
    }

    /// Executes this raw SQL on a write connection outside a transaction.
    ///
    /// ```swift
    /// try await database.writeWithoutTransaction { connection in
    ///   try #sql("VACUUM").execute(connection)
    /// }
    /// ```
    ///
    /// - Parameter connection: The write connection on which to execute the SQL.
    /// - Throws: A ``SQLiteError`` when the statement fails.
    public func execute(_ connection: borrowing SQLiteWriteConnection) throws {
      try connection.execute(SQL(fragment: query))
    }
  }

  // MARK: - Projected values

  extension PartialSelectStatement where QueryValue: QueryRepresentable {
    /// Returns a cursor that lazily decodes each value this statement selects.
    ///
    /// Nothing is read until the cursor is advanced, so a result set too large to hold in memory
    /// can still be walked. ``fetchAll(_:)`` is the eager equivalent. The cursor must be consumed
    /// inside the transaction.
    ///
    /// ```swift
    /// try await database.read { transaction in
    ///   var cursor = try Reminder.select(\.title).fetchCursor(transaction)
    ///   while let title = try cursor.next() { print(title) }
    /// }
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: A cursor over the decoded values, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseQueryCursor(base: try transaction.rowCursor(SQL(fragment: query), cached: false))
    }

    /// Fetches every value this statement selects.
    ///
    /// ```swift
    /// let titles = try await database.read { transaction in
    ///   try Reminder.select(\.title).fetchAll(transaction)
    /// }
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: Every decoded value, in the order the statement produced it.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
    public func fetchAll<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> [QueryValue.QueryOutput]
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>(
        base: try transaction.rowCursor(SQL(fragment: query), cached: true)
      )
      .collect()
    }

    /// Fetches the first value this statement selects.
    ///
    /// ```swift
    /// let count = try Reminder.all.count().fetchOne(transaction) ?? 0
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: The first decoded value, or `nil` when the statement produced no row.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
    public func fetchOne<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> QueryValue.QueryOutput?
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>(
        base: try transaction.rowCursor(SQL(fragment: query), cached: true)
      )
      .first()
    }
  }

  extension Statement where QueryValue: QueryRepresentable {
    /// Returns a cursor that lazily decodes each value this statement returns, such as from a
    /// `RETURNING` clause.
    ///
    /// The statement may write, so only a write transaction runs it. SQLite makes every change a
    /// `RETURNING` statement reports on its first step, so the rows the cursor leaves unread are
    /// written all the same.
    ///
    /// ```swift
    /// try await database.write { transaction in
    ///   var cursor = try Reminder.insert { Reminder.Draft(title: "Get milk") }
    ///     .returning(\.id)
    ///     .fetchCursor(transaction)
    ///   while let id = try cursor.next() { print(id) }
    /// }
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to run the statement.
    /// - Returns: A cursor over the decoded values, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>
    where
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseQueryCursor(
        base: try transaction.executeRowCursor(SQL(fragment: query), cached: false)
      )
    }

    /// Fetches every value this statement returns, such as from a `RETURNING` clause.
    ///
    /// ```swift
    /// let ids = try await database.write { transaction in
    ///   try Reminder.where(\.isCompleted).delete().returning(\.id).fetchAll(transaction)
    /// }
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to run the statement.
    /// - Returns: Every decoded value the statement returned.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
    public func fetchAll<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> [QueryValue.QueryOutput]
    where
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>(
        base: try transaction.executeRowCursor(SQL(fragment: query), cached: true)
      )
      .collect()
    }

    /// Fetches the first value this statement returns, such as from a `RETURNING` clause.
    ///
    /// Only the first row is read, but SQLite makes every change the statement reports on its
    /// first step, so the rows left unread are written all the same.
    ///
    /// ```swift
    /// let id = try Reminder.insert { Reminder.Draft(title: "Get milk") }
    ///   .returning(\.id)
    ///   .fetchOne(transaction)
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to run the statement.
    /// - Returns: The first decoded value, or `nil` when the statement returned no row.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
    public func fetchOne<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> QueryValue.QueryOutput?
    where
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>(
        base: try transaction.executeRowCursor(SQL(fragment: query), cached: true)
      )
      .first()
    }
  }

  extension SQLQueryExpression where QueryValue: QueryRepresentable {
    /// Returns a cursor that lazily decodes each value this raw SQL produces in a read
    /// transaction.
    ///
    /// The SQL is checked when it is prepared, and refused when it may write.
    ///
    /// ```swift
    /// var cursor = try #sql("SELECT title FROM reminders", as: String.self)
    ///   .fetchCursor(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the SQL.
    /// - Returns: A cursor over the decoded values, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or may write.
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseQueryCursor(base: try transaction.rowCursor(SQL(fragment: query), cached: false))
    }

    /// Fetches every value this raw SQL produces in a read transaction.
    ///
    /// ```swift
    /// let titles = try #sql("SELECT title FROM reminders ORDER BY id", as: String.self)
    ///   .fetchAll(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the SQL.
    /// - Returns: Every decoded value, in the order the SQL produced it.
    /// - Throws: A ``SQLiteError`` when the statement fails or may write, or a decoding error for
    ///   a row.
    public func fetchAll<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> [QueryValue.QueryOutput]
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>(
        base: try transaction.rowCursor(SQL(fragment: query), cached: true)
      )
      .collect()
    }

    /// Fetches the first value this raw SQL produces in a read transaction.
    ///
    /// ```swift
    /// let count = try #sql("SELECT count(*) FROM reminders", as: Int.self).fetchOne(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the SQL.
    /// - Returns: The first decoded value, or `nil` when the SQL produced no row.
    /// - Throws: A ``SQLiteError`` when the statement fails or may write, or a decoding error for
    ///   the row.
    public func fetchOne<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> QueryValue.QueryOutput?
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>(
        base: try transaction.rowCursor(SQL(fragment: query), cached: true)
      )
      .first()
    }

    /// Returns a cursor that lazily decodes each value this raw SQL returns in a write
    /// transaction, where it may write.
    ///
    /// ```swift
    /// var cursor = try #sql("DELETE FROM reminders RETURNING id", as: Int.self)
    ///   .fetchCursor(transaction)
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to run the SQL.
    /// - Returns: A cursor over the decoded values, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>
    where
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseQueryCursor(
        base: try transaction.executeRowCursor(SQL(fragment: query), cached: false)
      )
    }

    /// Fetches every value this raw SQL returns in a write transaction, where it may write.
    ///
    /// ```swift
    /// let ids = try #sql("DELETE FROM reminders RETURNING id", as: Int.self)
    ///   .fetchAll(transaction)
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to run the SQL.
    /// - Returns: Every decoded value the SQL returned.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
    public func fetchAll<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> [QueryValue.QueryOutput]
    where
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>(
        base: try transaction.executeRowCursor(SQL(fragment: query), cached: true)
      )
      .collect()
    }

    /// Fetches the first value this raw SQL returns in a write transaction, where it may write.
    ///
    /// - Parameter transaction: The write transaction in which to run the SQL.
    /// - Returns: The first decoded value, or `nil` when the SQL returned no row.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
    public func fetchOne<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> QueryValue.QueryOutput?
    where
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>(
        base: try transaction.executeRowCursor(SQL(fragment: query), cached: true)
      )
      .first()
    }
  }

  // MARK: - Tuple projections

  // The compiler cannot see through a cursor's `Element` when it is a pack expansion, so the eager
  // tuple fetches decode through `collectTuples` and `firstTuple` rather than a tuple cursor.

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension OrbitDatabaseRowCursor
  where Self: ~Copyable, Self: ~Escapable, Row: OrbitDatabaseStructuredRow {
    @_lifetime(self: copy self)
    mutating func collectTuples<each Value: QueryRepresentable>(
      _ type: (repeat each Value).Type
    ) throws -> [(repeat (each Value).QueryOutput)] {
      var values: [(repeat (each Value).QueryOutput)] = []
      try forEach { row in values.append(try row.decode((repeat each Value).self)) }
      return values
    }

    @_lifetime(self: copy self)
    mutating func firstTuple<each Value: QueryRepresentable>(
      _ type: (repeat each Value).Type
    ) throws -> (repeat (each Value).QueryOutput)? {
      guard var row = try next() else { return nil }
      return try row.decode((repeat each Value).self)
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension PartialSelectStatement {
    /// Returns a cursor that lazily decodes each tuple this statement selects.
    ///
    /// ```swift
    /// var cursor = try Reminder.select { ($0.id, $0.title) }.fetchCursor(transaction)
    /// while let (id, title) = try cursor.next() { print(id, title) }
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: A cursor over the decoded tuples, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_disfavoredOverload
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseTupleQueryCursor<Transaction.RowCursor, repeat each Value>
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseTupleQueryCursor(
        base: try transaction.rowCursor(SQL(fragment: query), cached: false)
      )
    }

    /// Fetches every tuple this statement selects.
    ///
    /// ```swift
    /// let rows = try Reminder.select { ($0.id, $0.title) }.fetchAll(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: Every decoded tuple, in the order the statement produced it.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
    @_disfavoredOverload
    public func fetchAll<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> [(repeat (each Value).QueryOutput)]
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try withOrbitCursor(try transaction.rowCursor(SQL(fragment: query), cached: true)) {
        cursor in
        try cursor.collectTuples((repeat each Value).self)
      }
    }

    /// Fetches the first tuple this statement selects.
    ///
    /// ```swift
    /// let first = try Reminder.select { ($0.id, $0.title) }.fetchOne(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: The first decoded tuple, or `nil` when the statement produced no row.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
    @_disfavoredOverload
    public func fetchOne<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> (repeat (each Value).QueryOutput)?
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try withOrbitCursor(try transaction.rowCursor(SQL(fragment: query), cached: true)) {
        cursor in
        try cursor.firstTuple((repeat each Value).self)
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension Statement {
    /// Returns a cursor that lazily decodes each tuple this statement returns, such as from a
    /// `RETURNING` clause.
    ///
    /// ```swift
    /// var cursor = try Reminder.insert { Reminder.Draft(title: "Get milk") }
    ///   .returning { ($0.id, $0.title) }
    ///   .fetchCursor(transaction)
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to run the statement.
    /// - Returns: A cursor over the decoded tuples, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_disfavoredOverload
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseTupleQueryCursor<Transaction.RowCursor, repeat each Value>
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseTupleQueryCursor(
        base: try transaction.executeRowCursor(SQL(fragment: query), cached: false)
      )
    }

    /// Fetches every tuple this statement returns, such as from a `RETURNING` clause.
    ///
    /// ```swift
    /// let deleted = try Reminder.where(\.isCompleted).delete()
    ///   .returning { ($0.id, $0.title) }
    ///   .fetchAll(transaction)
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to run the statement.
    /// - Returns: Every decoded tuple the statement returned.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
    @_disfavoredOverload
    public func fetchAll<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> [(repeat (each Value).QueryOutput)]
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try withOrbitCursor(try transaction.executeRowCursor(SQL(fragment: query), cached: true)) {
        cursor in
        try cursor.collectTuples((repeat each Value).self)
      }
    }

    /// Fetches the first tuple this statement returns, such as from a `RETURNING` clause.
    ///
    /// - Parameter transaction: The write transaction in which to run the statement.
    /// - Returns: The first decoded tuple, or `nil` when the statement returned no row.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
    @_disfavoredOverload
    public func fetchOne<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> (repeat (each Value).QueryOutput)?
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try withOrbitCursor(try transaction.executeRowCursor(SQL(fragment: query), cached: true)) {
        cursor in
        try cursor.firstTuple((repeat each Value).self)
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SQLQueryExpression {
    /// Returns a cursor that lazily decodes each tuple this raw SQL produces in a read
    /// transaction.
    ///
    /// ```swift
    /// var cursor = try #sql("SELECT id, title FROM reminders", as: (Int, String).self)
    ///   .fetchCursor(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the SQL.
    /// - Returns: A cursor over the decoded tuples, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound, or may write.
    @_disfavoredOverload
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseTupleQueryCursor<Transaction.RowCursor, repeat each Value>
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseTupleQueryCursor(
        base: try transaction.rowCursor(SQL(fragment: query), cached: false)
      )
    }

    /// Fetches every tuple this raw SQL produces in a read transaction.
    ///
    /// ```swift
    /// let rows = try #sql("SELECT id, title FROM reminders", as: (Int, String).self)
    ///   .fetchAll(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the SQL.
    /// - Returns: Every decoded tuple, in the order the SQL produced it.
    /// - Throws: A ``SQLiteError`` when the statement fails or may write, or a decoding error for
    ///   a row.
    @_disfavoredOverload
    public func fetchAll<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> [(repeat (each Value).QueryOutput)]
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try withOrbitCursor(try transaction.rowCursor(SQL(fragment: query), cached: true)) {
        cursor in
        try cursor.collectTuples((repeat each Value).self)
      }
    }

    /// Fetches the first tuple this raw SQL produces in a read transaction.
    ///
    /// - Parameter transaction: The transaction in which to run the SQL.
    /// - Returns: The first decoded tuple, or `nil` when the SQL produced no row.
    /// - Throws: A ``SQLiteError`` when the statement fails or may write, or a decoding error for
    ///   the row.
    @_disfavoredOverload
    public func fetchOne<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> (repeat (each Value).QueryOutput)?
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try withOrbitCursor(try transaction.rowCursor(SQL(fragment: query), cached: true)) {
        cursor in
        try cursor.firstTuple((repeat each Value).self)
      }
    }

    /// Returns a cursor that lazily decodes each tuple this raw SQL returns in a write
    /// transaction, where it may write.
    ///
    /// - Parameter transaction: The write transaction in which to run the SQL.
    /// - Returns: A cursor over the decoded tuples, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_disfavoredOverload
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseTupleQueryCursor<Transaction.RowCursor, repeat each Value>
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseTupleQueryCursor(
        base: try transaction.executeRowCursor(SQL(fragment: query), cached: false)
      )
    }

    /// Fetches every tuple this raw SQL returns in a write transaction, where it may write.
    ///
    /// ```swift
    /// let deleted = try #sql("DELETE FROM reminders RETURNING id, title", as: (Int, String).self)
    ///   .fetchAll(transaction)
    /// ```
    ///
    /// - Parameter transaction: The write transaction in which to run the SQL.
    /// - Returns: Every decoded tuple the SQL returned.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
    @_disfavoredOverload
    public func fetchAll<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> [(repeat (each Value).QueryOutput)]
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try withOrbitCursor(try transaction.executeRowCursor(SQL(fragment: query), cached: true)) {
        cursor in
        try cursor.collectTuples((repeat each Value).self)
      }
    }

    /// Fetches the first tuple this raw SQL returns in a write transaction, where it may write.
    ///
    /// - Parameter transaction: The write transaction in which to run the SQL.
    /// - Returns: The first decoded tuple, or `nil` when the SQL returned no row.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
    @_disfavoredOverload
    public func fetchOne<Transaction, each Value: QueryRepresentable>(
      _ transaction: borrowing Transaction
    ) throws -> (repeat (each Value).QueryOutput)?
    where
      QueryValue == (repeat each Value),
      Transaction: OrbitDatabaseWriteTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try withOrbitCursor(try transaction.executeRowCursor(SQL(fragment: query), cached: true)) {
        cursor in
        try cursor.firstTuple((repeat each Value).self)
      }
    }
  }

  // MARK: - Whole-table selects

  extension SelectStatement where QueryValue == (), Joins == () {
    /// Returns a cursor that lazily decodes each table value this statement selects.
    ///
    /// A statement with no explicit projection decodes its rows to its `FROM` table.
    ///
    /// ```swift
    /// try await database.read { transaction in
    ///   var cursor = try Reminder.where { !$0.isCompleted }.fetchCursor(transaction)
    ///   while let reminder = try cursor.next() { print(reminder.title) }
    /// }
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: A cursor over the decoded table values, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseQueryCursor<Transaction.RowCursor, From>
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseQueryCursor(base: try transaction.rowCursor(SQL(fragment: query), cached: false))
    }

    /// Fetches every table value this statement selects.
    ///
    /// ```swift
    /// let pending = try await database.read { transaction in
    ///   try Reminder.where { !$0.isCompleted }.fetchAll(transaction)
    /// }
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: Every decoded row of the statement's `FROM` table.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
    public func fetchAll<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> [From.QueryOutput]
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try OrbitDatabaseQueryCursor<Transaction.RowCursor, From>(
        base: try transaction.rowCursor(SQL(fragment: query), cached: true)
      )
      .collect()
    }

    /// Fetches the first table value this statement selects.
    ///
    /// A `LIMIT 1` is added, so only one row is read.
    ///
    /// ```swift
    /// let newest = try Reminder.order { $0.id.desc() }.fetchOne(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: The first decoded row, or `nil` when the statement produced none.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
    public func fetchOne<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> From.QueryOutput?
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      let statement = asSelect().limit(1)
      return try OrbitDatabaseQueryCursor<Transaction.RowCursor, From>(
        base: try transaction.rowCursor(SQL(fragment: statement.query), cached: true)
      )
      .first()
    }

    /// Returns the number of rows this statement selects.
    ///
    /// The counting is done by SQLite, so no row is decoded.
    ///
    /// ```swift
    /// let pending = try Reminder.where { !$0.isCompleted }.fetchCount(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: How many rows the statement would produce.
    /// - Throws: A ``SQLiteError`` when the statement fails.
    public func fetchCount<Transaction>(
      _ transaction: borrowing Transaction
    ) throws -> Int
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try asSelect().count().fetchOne(transaction) ?? 0
    }
  }

  extension SelectStatement where QueryValue == (), Joins == (), From: PrimaryKeyedTable {
    /// Fetches the row with the given primary key.
    ///
    /// ```swift
    /// let reminder = try Reminder.all.find(transaction, key: 42)
    /// ```
    ///
    /// - Parameters:
    ///   - transaction: The transaction in which to run the statement.
    ///   - primaryKey: The key to look up.
    /// - Returns: The row with that key.
    /// - Throws: ``OrbitDatabaseRecordNotFoundError`` if no row has that primary key, or a
    ///   ``SQLiteError`` when the statement fails.
    public func find<Transaction>(
      _ transaction: borrowing Transaction,
      key primaryKey: some QueryExpression<From.PrimaryKey>
    ) throws -> From.QueryOutput
    where
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      guard let record = try asSelect().find(primaryKey).fetchOne(transaction) else {
        throw OrbitDatabaseRecordNotFoundError()
      }
      return record
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SelectStatement where QueryValue == () {
    /// Returns a cursor that lazily decodes each joined row this statement selects.
    ///
    /// The statement's `FROM` table comes first, then each joined table in the order it was
    /// joined.
    ///
    /// ```swift
    /// var cursor = try Reminder.join(List.all) { $0.listID.eq($1.id) }.fetchCursor(transaction)
    /// while let (reminder, list) = try cursor.next() { print(reminder.title, list.name) }
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: A cursor over the decoded rows, valid until the transaction ends.
    /// - Throws: A ``SQLiteError`` when the statement cannot be prepared or bound.
    @_disfavoredOverload
    @_lifetime(borrow transaction)
    public func fetchCursor<Transaction, each Joined: Table>(
      _ transaction: borrowing Transaction
    ) throws -> OrbitDatabaseTupleQueryCursor<Transaction.RowCursor, From, repeat each Joined>
    where
      Joins == (repeat each Joined),
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      OrbitDatabaseTupleQueryCursor(
        base: try transaction.rowCursor(SQL(fragment: selectStar().query), cached: false)
      )
    }

    /// Fetches every joined row this statement selects.
    ///
    /// ```swift
    /// let rows = try Reminder.join(List.all) { $0.listID.eq($1.id) }.fetchAll(transaction)
    /// ```
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: Every decoded row, its `FROM` table first and each joined table after it.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for a row.
    @_disfavoredOverload
    public func fetchAll<Transaction, each Joined: Table>(
      _ transaction: borrowing Transaction
    ) throws -> [(From.QueryOutput, repeat (each Joined).QueryOutput)]
    where
      Joins == (repeat each Joined),
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try selectStar().fetchAll(transaction)
    }

    /// Fetches the first joined row this statement selects.
    ///
    /// A `LIMIT 1` is added, so only one row is read.
    ///
    /// - Parameter transaction: The transaction in which to run the statement.
    /// - Returns: The first decoded row, or `nil` when the statement produced none.
    /// - Throws: A ``SQLiteError`` when the statement fails, or a decoding error for the row.
    @_disfavoredOverload
    public func fetchOne<Transaction, each Joined: Table>(
      _ transaction: borrowing Transaction
    ) throws -> (From.QueryOutput, repeat (each Joined).QueryOutput)?
    where
      Joins == (repeat each Joined),
      Transaction: OrbitDatabaseReadTransaction,
      Transaction: ~Copyable,
      Transaction: ~Escapable,
      Transaction.Row: OrbitDatabaseStructuredRow
    {
      try asSelect().limit(1).selectStar().fetchOne(transaction)
    }
  }
#endif
