/// The settings an access may change on a connection, each kept beside the value the connection's
/// configuration gave it.
///
/// A setting counts as changed for as long as its current value differs from its configured one.
/// The handle restores every changed setting when an access ends and again, for whatever could not
/// be restored then, before the next access begins, so no access runs under a setting an earlier
/// one left behind. Only changes made through here are known: a raw `PRAGMA` is not tracked.
final class SQLiteConnectionSettings {
  private let library: UnsafePointer<SQLiteLibrary>
  private let connection: OpaquePointer
  private let authorizer: SQLiteAuthorizerDispatcher
  private let statements: SQLiteStatementCache

  private let configuredBusyTimeout: SQLiteBusyTimeout
  private let configuredForeignKeys: Bool

  private(set) var busyTimeout: SQLiteBusyTimeout
  private(set) var isForeignKeysEnabled: Bool

  // Configured off. A connection that can write turns it on only for the duration of a read.
  private(set) var isQueryOnly = false

  init(
    library: UnsafePointer<SQLiteLibrary>,
    connection: OpaquePointer,
    authorizer: SQLiteAuthorizerDispatcher,
    statements: SQLiteStatementCache,
    busyTimeout: SQLiteBusyTimeout,
    isForeignKeysEnabled: Bool
  ) {
    self.library = library
    self.connection = connection
    self.authorizer = authorizer
    self.statements = statements
    self.configuredBusyTimeout = busyTimeout
    self.configuredForeignKeys = isForeignKeysEnabled
    self.busyTimeout = busyTimeout
    self.isForeignKeysEnabled = isForeignKeysEnabled
  }

  private var hasChanges: Bool {
    busyTimeout != configuredBusyTimeout
      || isForeignKeysEnabled != configuredForeignKeys
      || isQueryOnly
  }

  func setBusyTimeout(_ timeout: SQLiteBusyTimeout) {
    // `sqlite3_busy_timeout` only refuses a connection that is not open, and one lent to an access
    // always is. Were it to refuse anyway, the timeout in effect is unchanged, and so is what this
    // reports.
    guard applyBusyTimeout(timeout) == SQLiteResultCode.ok.rawValue else { return }
    busyTimeout = timeout
  }

  func setForeignKeysEnabled(_ isEnabled: Bool) throws {
    // Numeric booleans are accepted by both SQLite and Turso. The statement runs the way one the
    // connection executes does, so cached statements compiled under the old setting are dropped.
    try SQLiteHandle.execute(
      "PRAGMA foreign_keys = \(isEnabled ? 1 : 0)",
      on: connection,
      library: library,
      authorizer: authorizer,
      statements: statements
    )
    isForeignKeysEnabled = isEnabled
  }

  func setQueryOnly(_ isQueryOnly: Bool) throws {
    // Numeric booleans are accepted by both SQLite and Turso. Turso currently parses the `ON`
    // keyword as a different expression kind than the pragma implementation accepts.
    try SQLiteHandle.execute(
      "PRAGMA query_only = \(isQueryOnly ? 1 : 0)",
      on: connection,
      library: library
    )
    self.isQueryOnly = isQueryOnly
  }

  /// Puts every changed setting back to its configured value.
  ///
  /// Every changed setting is attempted even after one fails, so one failure leaves no more
  /// behind than it has to. A setting that cannot be restored stays changed.
  ///
  /// - Throws: The first failure.
  func restore() throws {
    guard hasChanges else { return }
    var failure: (any Error)?
    if busyTimeout != configuredBusyTimeout {
      // Reapplying the timeout replaces any busy handler a connection setup installed, which is
      // why it is only reapplied once it has actually changed.
      let code = applyBusyTimeout(configuredBusyTimeout)
      if code == SQLiteResultCode.ok.rawValue {
        busyTimeout = configuredBusyTimeout
      } else {
        failure = SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: nil)
      }
    }
    if isForeignKeysEnabled != configuredForeignKeys {
      do {
        try setForeignKeysEnabled(configuredForeignKeys)
      } catch {
        failure = failure ?? error
      }
    }
    if isQueryOnly {
      do {
        try setQueryOnly(false)
      } catch {
        failure = failure ?? error
      }
    }
    if let failure { throw failure }
  }

  private func applyBusyTimeout(_ timeout: SQLiteBusyTimeout) -> Int32 {
    library.pointee.connections.setBusyTimeout(connection, timeout.milliseconds)
  }
}
