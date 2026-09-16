public import StructuredQueriesSQLite

// SQLiteData spells its query operations with the statement first (`statement.fetchAll(db)`).
// Orbit's transaction-first operations remain the implementation seam; these overloads make a
// query body portable between the two libraries without weakening Orbit's access capabilities.

// MARK: - Execution

extension Statement where QueryValue == () {
  /// Executes this statement in a write transaction, discarding any rows it returns.
  ///
  /// ```swift
  /// try await database.write { transaction in
  ///   try Reminder.insert { Reminder.Draft(title: "Buy milk") }.execute(transaction)
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
    try transaction.execute(self)
  }

  /// Executes this statement on a write connection outside a transaction.
  ///
  /// Each statement commits on its own. This overload is primarily for work that cannot run in a
  /// transaction, such as `VACUUM` or changing foreign-key enforcement.
  ///
  /// - Parameter connection: The write connection on which to execute the statement.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  public func execute(_ connection: borrowing SQLiteWriteConnection) throws {
    try connection.execute(self)
  }
}

extension PartialSelectStatement where QueryValue == () {
  /// Executes this read statement, discarding any rows it returns.
  ///
  /// Prefer a `fetch` operation when the rows are useful.
  ///
  /// - Parameter transaction: The read transaction in which to execute the statement.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  public func execute<Transaction>(
    _ transaction: borrowing Transaction
  ) throws
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    var cursor = try transaction.rowCursor(self)
    while try cursor.next() != nil {}
  }
}

extension SQLQueryExpression where QueryValue == () {
  /// Executes this raw SQL, discarding any rows it returns.
  ///
  /// Raw SQL has no statically knowable access capability, so it is accepted by a read
  /// transaction. A statement that actually writes still fails at runtime because Orbit makes
  /// every read access query-only.
  ///
  /// - Parameter transaction: The transaction in which to execute the SQL.
  /// - Throws: A ``SQLiteError`` when the statement fails, including `SQLITE_READONLY` when it
  ///   attempts to write during read access.
  public func execute<Transaction>(
    _ transaction: borrowing Transaction
  ) throws
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    var cursor = try transaction.rowCursor(self)
    while try cursor.next() != nil {}
  }

  /// Executes this raw SQL on a write connection outside a transaction.
  ///
  /// - Parameter connection: The write connection on which to execute the SQL.
  /// - Throws: A ``SQLiteError`` when the statement fails.
  public func execute(_ connection: borrowing SQLiteWriteConnection) throws {
    try connection.execute(self)
  }
}

// MARK: - Projected values

extension PartialSelectStatement where QueryValue: QueryRepresentable {
  /// Returns a cursor over the values selected by this statement.
  @_lifetime(borrow transaction)
  public func fetchCursor<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchCursor(self)
  }

  /// Fetches every value selected by this statement.
  public func fetchAll<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> [QueryValue.QueryOutput]
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchAll(self)
  }

  /// Fetches the first value selected by this statement.
  public func fetchOne<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> QueryValue.QueryOutput?
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchOne(self)
  }
}

extension Statement where QueryValue: QueryRepresentable {
  /// Returns a cursor over the values returned by this write statement.
  @_lifetime(borrow transaction)
  public func fetchCursor<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>
  where
    Transaction: OrbitDatabaseWriteTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.executeCursor(self)
  }

  /// Fetches every value returned by this write statement.
  public func fetchAll<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> [QueryValue.QueryOutput]
  where
    Transaction: OrbitDatabaseWriteTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchAll(self)
  }

  /// Fetches the first value returned by this write statement.
  public func fetchOne<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> QueryValue.QueryOutput?
  where
    Transaction: OrbitDatabaseWriteTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchOne(self)
  }
}

extension SQLQueryExpression where QueryValue: QueryRepresentable {
  /// Returns a cursor over the values produced by this raw SQL.
  @_lifetime(borrow transaction)
  public func fetchCursor<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> OrbitDatabaseQueryCursor<Transaction.RowCursor, QueryValue>
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchCursor(self)
  }

  /// Fetches every value produced by this raw SQL.
  public func fetchAll<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> [QueryValue.QueryOutput]
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchAll(self)
  }

  /// Fetches the first value produced by this raw SQL.
  public func fetchOne<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> QueryValue.QueryOutput?
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchOne(self)
  }
}

// MARK: - Tuple projections

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension PartialSelectStatement {
  /// Returns a cursor over the tuples selected by this statement.
  @_disfavoredOverload
  @_lifetime(borrow transaction)
  public func fetchCursor<Transaction, each Value: QueryRepresentable>(
    _ transaction: borrowing Transaction
  ) throws -> OrbitDatabaseTupleQueryCursor<Transaction.RowCursor, repeat each Value>
  where
    QueryValue == (repeat each Value),
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchCursor(self)
  }

  /// Fetches every tuple selected by this statement.
  @_disfavoredOverload
  public func fetchAll<Transaction, each Value: QueryRepresentable>(
    _ transaction: borrowing Transaction
  ) throws -> [(repeat (each Value).QueryOutput)]
  where
    QueryValue == (repeat each Value),
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchAll(self)
  }

  /// Fetches the first tuple selected by this statement.
  @_disfavoredOverload
  public func fetchOne<Transaction, each Value: QueryRepresentable>(
    _ transaction: borrowing Transaction
  ) throws -> (repeat (each Value).QueryOutput)?
  where
    QueryValue == (repeat each Value),
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchOne(self)
  }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension Statement {
  /// Returns a cursor over the tuples returned by this write statement.
  @_disfavoredOverload
  @_lifetime(borrow transaction)
  public func fetchCursor<Transaction, each Value: QueryRepresentable>(
    _ transaction: borrowing Transaction
  ) throws -> OrbitDatabaseTupleQueryCursor<Transaction.RowCursor, repeat each Value>
  where
    QueryValue == (repeat each Value),
    Transaction: OrbitDatabaseWriteTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.executeCursor(self)
  }

  /// Fetches every tuple returned by this write statement.
  @_disfavoredOverload
  public func fetchAll<Transaction, each Value: QueryRepresentable>(
    _ transaction: borrowing Transaction
  ) throws -> [(repeat (each Value).QueryOutput)]
  where
    QueryValue == (repeat each Value),
    Transaction: OrbitDatabaseWriteTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchAll(self)
  }

  /// Fetches the first tuple returned by this write statement.
  @_disfavoredOverload
  public func fetchOne<Transaction, each Value: QueryRepresentable>(
    _ transaction: borrowing Transaction
  ) throws -> (repeat (each Value).QueryOutput)?
  where
    QueryValue == (repeat each Value),
    Transaction: OrbitDatabaseWriteTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchOne(self)
  }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension SQLQueryExpression {
  /// Returns a cursor over the tuples produced by this raw SQL.
  @_disfavoredOverload
  @_lifetime(borrow transaction)
  public func fetchCursor<Transaction, each Value: QueryRepresentable>(
    _ transaction: borrowing Transaction
  ) throws -> OrbitDatabaseTupleQueryCursor<Transaction.RowCursor, repeat each Value>
  where
    QueryValue == (repeat each Value),
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchCursor(self)
  }

  /// Fetches every tuple produced by this raw SQL.
  @_disfavoredOverload
  public func fetchAll<Transaction, each Value: QueryRepresentable>(
    _ transaction: borrowing Transaction
  ) throws -> [(repeat (each Value).QueryOutput)]
  where
    QueryValue == (repeat each Value),
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchAll(self)
  }

  /// Fetches the first tuple produced by this raw SQL.
  @_disfavoredOverload
  public func fetchOne<Transaction, each Value: QueryRepresentable>(
    _ transaction: borrowing Transaction
  ) throws -> (repeat (each Value).QueryOutput)?
  where
    QueryValue == (repeat each Value),
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchOne(self)
  }
}

// MARK: - Whole-table selects

extension SelectStatement where QueryValue == (), Joins == () {
  /// Returns a cursor over the table values selected by this statement.
  @_lifetime(borrow transaction)
  public func fetchCursor<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> OrbitDatabaseQueryCursor<Transaction.RowCursor, From>
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchCursor(self)
  }

  /// Fetches every table value selected by this statement.
  public func fetchAll<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> [From.QueryOutput]
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchAll(self)
  }

  /// Fetches the first table value selected by this statement.
  public func fetchOne<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> From.QueryOutput?
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchOne(self)
  }

  /// Returns the number of rows selected by this statement.
  public func fetchCount<Transaction>(
    _ transaction: borrowing Transaction
  ) throws -> Int
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchCount(self)
  }
}

extension SelectStatement where QueryValue == (), Joins == (), From: PrimaryKeyedTable {
  /// Fetches the row having the given primary key.
  public func find<Transaction>(
    _ transaction: borrowing Transaction,
    key primaryKey: some QueryExpression<From.PrimaryKey>
  ) throws -> From.QueryOutput
  where
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.find(self, key: primaryKey)
  }
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension SelectStatement where QueryValue == () {
  /// Returns a cursor over the joined rows selected by this statement.
  @_disfavoredOverload
  @_lifetime(borrow transaction)
  public func fetchCursor<Transaction, each Joined: Table>(
    _ transaction: borrowing Transaction
  ) throws -> OrbitDatabaseTupleQueryCursor<Transaction.RowCursor, From, repeat each Joined>
  where
    Joins == (repeat each Joined),
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchCursor(self)
  }

  /// Fetches every joined row selected by this statement.
  @_disfavoredOverload
  public func fetchAll<Transaction, each Joined: Table>(
    _ transaction: borrowing Transaction
  ) throws -> [(From.QueryOutput, repeat (each Joined).QueryOutput)]
  where
    Joins == (repeat each Joined),
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchAll(self)
  }

  /// Fetches the first joined row selected by this statement.
  @_disfavoredOverload
  public func fetchOne<Transaction, each Joined: Table>(
    _ transaction: borrowing Transaction
  ) throws -> (From.QueryOutput, repeat (each Joined).QueryOutput)?
  where
    Joins == (repeat each Joined),
    Transaction: OrbitDatabaseReadTransaction,
    Transaction: ~Copyable,
    Transaction: ~Escapable
  {
    try transaction.fetchOne(self)
  }
}
