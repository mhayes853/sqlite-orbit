extension SQLiteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Splits the first statement SQLite would run off the front of `sql`, without running it.
  ///
  /// SQLite finds where the statement ends, so a semicolon inside a string, a comment or a
  /// trigger body does not end it. Empty statements and comments before the first statement are
  /// skipped over, and are part of the text returned for it.
  ///
  /// The statement is compiled to find its end, against the schema as it stands now, so SQL
  /// naming a table that does not exist yet fails to split. Run each statement before splitting
  /// off the next to split a script whose later statements depend on earlier ones:
  ///
  /// ```swift
  /// try await database.write { transaction in
  ///   var remaining = script[...]
  ///   while let (statement, remainder) = try transaction.firstStatement(in: remaining) {
  ///     try transaction.execute(SQL(text: statement))
  ///     remaining = remainder
  ///   }
  /// }
  /// ```
  ///
  /// - Parameter sql: The SQL to split.
  /// - Returns: The text of the first statement and what follows it, or `nil` when `sql` holds
  ///   only whitespace, comments and empty statements.
  /// - Throws: A ``SQLiteError`` when SQLite cannot compile the first statement.
  public borrowing func firstStatement<Text: StringProtocol>(
    in sql: Text
  ) throws -> (statement: String, remainder: Text.SubSequence)? {
    try sqliteFirstStatement(in: sql, on: sqliteConnection, library: sqlite)
  }
}

extension SQLiteConnectionAccess {
  /// Splits the first statement SQLite would run off the front of `sql`, without running it.
  ///
  /// SQLite finds where the statement ends, so a semicolon inside a string, a comment or a
  /// trigger body does not end it. Empty statements and comments before the first statement are
  /// skipped over, and are part of the text returned for it.
  ///
  /// The statement is compiled to find its end, against the schema as it stands now, so SQL
  /// naming a table that does not exist yet fails to split.
  ///
  /// ```swift
  /// let (first, rest) = try connection.firstStatement(in: script) ?? ("", "")
  /// ```
  ///
  /// - Parameter sql: The SQL to split.
  /// - Returns: The text of the first statement and what follows it, or `nil` when `sql` holds
  ///   only whitespace, comments and empty statements.
  /// - Throws: A ``SQLiteError`` when SQLite cannot compile the first statement.
  public borrowing func firstStatement<Text: StringProtocol>(
    in sql: Text
  ) throws -> (statement: String, remainder: Text.SubSequence)? {
    try sqliteFirstStatement(in: sql, on: sqliteConnection, library: sqlite)
  }
}

func sqliteFirstStatement<Text: StringProtocol>(
  in sql: Text,
  on connection: OpaquePointer,
  library: SQLiteLibrary
) throws -> (statement: String, remainder: Text.SubSequence)? {
  let utf8 = sql.utf8
  // Native strings lend their bytes in place, so splitting a long script one statement at a time
  // does not copy what is left of it on every call.
  let split = { (bytes: UnsafeBufferPointer<UInt8>) in
    try sqliteFirstStatementLength(in: bytes, on: connection, library: library, sql: sql)
  }
  let length =
    try utf8.withContiguousStorageIfAvailable(split) ?? Array(utf8).withUnsafeBufferPointer(split)
  guard let length else { return nil }
  let end = utf8.index(utf8.startIndex, offsetBy: length)
  return (String(sql[..<end]), sql[end...])
}

// How many bytes the first statement in `bytes` takes up, counting the empty statements and
// comments before it, or `nil` when there is none.
private func sqliteFirstStatementLength(
  in bytes: UnsafeBufferPointer<UInt8>,
  on connection: OpaquePointer,
  library: SQLiteLibrary,
  sql: some StringProtocol
) throws -> Int? {
  guard let base = bytes.baseAddress else { return nil }
  return try base.withMemoryRebound(to: CChar.self, capacity: bytes.count) { start in
    let end = start + bytes.count
    var next = start
    while next < end {
      var statement: OpaquePointer?
      var tail: UnsafePointer<CChar>?
      let code = library.statements.preparation.prepare(
        connection,
        next,
        Int32(end - next),
        0,
        &statement,
        &tail
      )
      if let statement { _ = library.statements.execution.finalize(statement) }
      guard code == SQLiteResultCode.ok.rawValue else {
        throw SQLiteError.reported(by: library, on: connection, code: code, sql: String(sql))
      }
      // SQLite always moves past an empty statement, but stop rather than spin should it not.
      guard let tail, tail > next else { return nil }
      if statement != nil { return start.distance(to: tail) }
      next = tail
    }
    return nil
  }
}
