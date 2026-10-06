#if StructuredQueries
  import StructuredQueriesSQLite

  extension PrimaryKeyedTable where QueryOutput == Self, PrimaryKey.QueryOutput: Equatable {
    /// Reads and mutates an existing row in the supplied write transaction.
    ///
    /// Reads the latest value before applying `mutation`, so an edit does not overwrite unrelated
    /// changes made before the transaction began. The row's primary key must remain unchanged.
    /// This does not insert a missing row or commit the transaction.
    ///
    /// ```swift
    /// try await database.write { transaction in
    ///   try Reminder.update(id: reminderID, in: transaction) { reminder in
    ///     reminder.title = "Buy milk"
    ///   }
    /// }
    /// ```
    ///
    /// - Returns: The result of `mutation`.
    /// - Throws: `OrbitDatabaseRecordNotFoundError` if the row is missing or the update affects no
    ///   row, `OrbitRowIdentityMismatchError` if the mutation changes its key, or any mutation or
    ///   database error. Let the error propagate from the write closure to roll back its changes.
    @discardableResult
    public static func update<Result>(
      id primaryKey: PrimaryKey.QueryOutput,
      in transaction: borrowing SQLiteWriteTransaction,
      _ mutation: (inout Self) throws -> Result
    ) throws -> Result {
      var value = try transaction.find(Self.all, key: PrimaryKey(queryOutput: primaryKey))
      let result = try mutation(&value)
      guard value.primaryKey == primaryKey else {
        throw OrbitRowIdentityMismatchError()
      }
      try transaction.execute(Self.update(value))
      guard transaction.changesCount == 1 else {
        throw OrbitDatabaseRecordNotFoundError()
      }
      return result
    }
  }
#endif
