extension SQLiteReadConnection {
  /// Uses a busy policy for `body`, then restores the policy in effect before it.
  ///
  /// ```swift
  /// try await database.readWithoutTransaction { connection in
  ///   try connection.withBusyPolicy(.waitIndefinitely) {
  ///     try connection.fetchAll("SELECT title FROM reminders") { $0[0].textValue }
  ///   }
  /// }
  /// ```
  ///
  /// Scopes may nest. Restoration is attempted even when `body` throws; its error takes precedence
  /// over a restoration error. After a successful body, a restoration error is thrown. Connection
  /// access cleanup retries restoring the configured settings if necessary. Handlers installed
  /// through raw SQLite APIs cannot be restored.
  ///
  /// - Throws: A ``SQLiteFeatureUnavailableError`` for a ``SQLiteBusyPolicy/handler(_:)`` the
  ///   library cannot install, a ``SQLiteError`` when the policy cannot be applied or restored, or
  ///   whatever `body` throws.
  public borrowing func withBusyPolicy<Result: ~Copyable>(
    _ policy: SQLiteBusyPolicy,
    perform body: () throws -> Result
  ) throws -> Result {
    try handle.pointee.withBusyPolicy(policy, perform: body)
  }
}

extension SQLiteWriteConnection {
  /// Uses a busy policy for `body`, then restores the policy in effect before it.
  ///
  /// ```swift
  /// try await database.writeWithoutTransaction { connection in
  ///   try connection.withBusyPolicy(.waitIndefinitely) {
  ///     try connection.executeScript("VACUUM")
  ///   }
  /// }
  /// ```
  ///
  /// Scopes may nest. Restoration is attempted even when `body` throws; its error takes precedence
  /// over a restoration error. After a successful body, a restoration error is thrown. Connection
  /// access cleanup retries restoring the configured settings if necessary. Handlers installed
  /// through raw SQLite APIs cannot be restored.
  ///
  /// - Throws: A ``SQLiteFeatureUnavailableError`` for a ``SQLiteBusyPolicy/handler(_:)`` the
  ///   library cannot install, a ``SQLiteError`` when the policy cannot be applied or restored, or
  ///   whatever `body` throws.
  public borrowing func withBusyPolicy<Result: ~Copyable>(
    _ policy: SQLiteBusyPolicy,
    perform body: () throws -> Result
  ) throws -> Result {
    try handle.pointee.withBusyPolicy(policy, perform: body)
  }

  /// Uses foreign-key enforcement for `body`, then restores its previous setting.
  ///
  /// Call this outside a transaction; `body` can open transactions with `transaction`.
  /// Scopes may nest. Restoration bypasses user authorization and is attempted even when `body`
  /// throws; its error takes precedence over a restoration error. After a successful body, a
  /// restoration error is thrown. Connection access cleanup retries restoring the configured
  /// setting if necessary. Raw `PRAGMA` changes are not tracked.
  public borrowing func withForeignKeysEnabled<Result: ~Copyable>(
    _ enabled: Bool,
    perform body: () throws -> Result
  ) throws -> Result {
    let settings = handle.pointee.settings
    let previous = settings.pointee.isForeignKeysEnabled
    try settings.pointee.setForeignKeysEnabled(enabled)
    return try withRestoredSQLiteSetting {
      try handle.pointee.authorizer.withoutUserAuthorization {
        try settings.pointee.setForeignKeysEnabled(previous)
      }
    } perform: {
      try body()
    }
  }
}

extension SQLiteConnection {
  fileprivate borrowing func withBusyPolicy<Result: ~Copyable>(
    _ policy: SQLiteBusyPolicy,
    perform body: () throws -> Result
  ) throws -> Result {
    let previous = settings.pointee.busyPolicy
    let isConfigured = settings.pointee.isBusyPolicyConfigured
    try settings.pointee.setBusyPolicy(policy)
    return try withRestoredSQLiteSetting {
      try settings.pointee.restoreBusyPolicy(previous, isConfigured: isConfigured)
    } perform: {
      try body()
    }
  }
}

private func withRestoredSQLiteSetting<Result: ~Copyable>(
  restore: () throws -> Void,
  perform body: () throws -> Result
) throws -> Result {
  let result: Result
  do {
    result = try body()
  } catch {
    try? restore()
    throw error
  }
  try restore()
  return result
}
