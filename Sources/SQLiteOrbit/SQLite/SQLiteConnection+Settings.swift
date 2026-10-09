extension SQLiteReadConnection {
  /// Uses a busy timeout for `body`, then restores the previous timeout and configured handler.
  ///
  /// Scopes may nest. Restoration is attempted even when `body` throws; its error takes precedence
  /// over a restoration error. After a successful body, a restoration error is thrown. Connection
  /// access cleanup retries restoring the configured settings if necessary. Handlers installed
  /// through raw SQLite APIs cannot be restored.
  public borrowing func withBusyTimeout<Result: ~Copyable>(
    _ timeout: SQLiteBusyTimeout,
    perform body: () throws -> Result
  ) throws -> Result {
    try handle.pointee.withBusyTimeout(timeout, perform: body)
  }
}

extension SQLiteWriteConnection {
  /// Uses a busy timeout for `body`, then restores the previous timeout and configured handler.
  ///
  /// Scopes may nest. Restoration is attempted even when `body` throws; its error takes precedence
  /// over a restoration error. After a successful body, a restoration error is thrown. Connection
  /// access cleanup retries restoring the configured settings if necessary. Handlers installed
  /// through raw SQLite APIs cannot be restored.
  public borrowing func withBusyTimeout<Result: ~Copyable>(
    _ timeout: SQLiteBusyTimeout,
    perform body: () throws -> Result
  ) throws -> Result {
    try handle.pointee.withBusyTimeout(timeout, perform: body)
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
  fileprivate borrowing func withBusyTimeout<Result: ~Copyable>(
    _ timeout: SQLiteBusyTimeout,
    perform body: () throws -> Result
  ) throws -> Result {
    let previous = settings.pointee.busyTimeout
    let handlerIsReplaced = settings.pointee.isBusyHandlerReplaced
    try settings.pointee.setBusyTimeout(timeout)
    return try withRestoredSQLiteSetting {
      try settings.pointee.restoreBusyTimeout(previous, handlerIsReplaced: handlerIsReplaced)
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
