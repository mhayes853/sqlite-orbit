/// The settings an access may change on a connection, each kept beside the value the connection's
/// configuration gave it.
///
/// A setting counts as changed for as long as the value in effect on the connection differs from
/// its configured one. The configuration's busy handler counts too, since setting the busy timeout
/// is what SQLite replaces it with. The handle restores every changed setting when an access ends
/// and again, for whatever could not be restored then, before the next access begins, so no access
/// runs under a setting an earlier one left behind. Only changes made through here are known: a
/// raw `PRAGMA` is not tracked.
///
/// The handle keeps this in storage of its own rather than inline, since the handle is only ever
/// borrowed and the settings still have to change.
struct SQLiteConnectionSettings: ~Copyable {
  private let library: UnsafePointer<SQLiteLibrary>
  private let connection: OpaquePointer
  private let authorizer: SQLiteAuthorizerDispatcher
  private let statements: SQLiteStatementCache
  private let configuration: UnsafeMutablePointer<SQLiteConfiguration>

  private let configuredBusyTimeout: SQLiteBusyTimeout
  private let configuredForeignKeys: Bool

  // Setting the busy timeout replaces the configured busy handler, since SQLite keeps only one of
  // the two. Restoring the timeout is not enough to undo that, and a timeout set to the configured
  // value is not a change to restore at all, so the replacement is tracked on its own.
  private(set) var isBusyHandlerReplaced = false

  private(set) var busyTimeout: SQLiteBusyTimeout

  private(set) var isForeignKeysEnabled: Bool
  // A pragma can change the native flag during preparation even if stepping later fails. If
  // recovery also fails, the next access must restore it even when the last known value matches.
  private var needsForeignKeysRestore = false

  // Configured off. A connection that can write turns it on only for the duration of a read.
  private(set) var isQueryOnly = false

  init(
    library: UnsafePointer<SQLiteLibrary>,
    connection: OpaquePointer,
    authorizer: SQLiteAuthorizerDispatcher,
    statements: SQLiteStatementCache,
    configuration: UnsafeMutablePointer<SQLiteConfiguration>
  ) {
    self.library = library
    self.connection = connection
    self.authorizer = authorizer
    self.statements = statements
    self.configuration = configuration
    self.configuredBusyTimeout = configuration.pointee.busyTimeout
    self.configuredForeignKeys = configuration.pointee.isForeignKeysEnabled
    self.busyTimeout = configuration.pointee.busyTimeout
    self.isForeignKeysEnabled = configuration.pointee.isForeignKeysEnabled
  }

  mutating func setBusyTimeout(_ timeout: SQLiteBusyTimeout) throws {
    let code = library.pointee.connections.setBusyTimeout(connection, timeout.milliseconds)
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: nil)
    }
    busyTimeout = timeout
    if configuration.pointee.busyHandler != nil { isBusyHandlerReplaced = true }
  }

  mutating func setForeignKeysEnabled(_ isEnabled: Bool) throws {
    guard library.pointee.connections.isAutocommit(connection) != 0 else {
      throw SQLiteError(
        code: .misuse,
        message: "Foreign keys cannot be changed inside a transaction"
      )
    }
    guard isForeignKeysEnabled != isEnabled || needsForeignKeysRestore else { return }
    let previous = isForeignKeysEnabled
    do {
      try executeForeignKeys(isEnabled)
    } catch {
      needsForeignKeysRestore = true
      authorizer.withoutUserAuthorization { try? executeForeignKeys(previous) }
      throw error
    }
  }

  private mutating func executeForeignKeys(_ isEnabled: Bool) throws {
    // Numeric booleans are accepted by both SQLite and Turso. The statement runs the way one the
    // connection executes does, so cached statements compiled under the old setting are dropped.
    try authorizer.requiringExecution {
      try SQLiteConnection.executeScript(
        "PRAGMA foreign_keys = \(isEnabled ? 1 : 0)",
        on: connection,
        library: library,
        authorizer: authorizer,
        statements: statements
      )
    }
    isForeignKeysEnabled = isEnabled
    needsForeignKeysRestore = false
  }

  mutating func setQueryOnly(_ isQueryOnly: Bool) throws {
    // Numeric booleans are accepted by both SQLite and Turso. Turso currently parses the `ON`
    // keyword as a different expression kind than the pragma implementation accepts.
    try authorizer.requiringExecution {
      try SQLiteConnection.executeScript(
        "PRAGMA query_only = \(isQueryOnly ? 1 : 0)",
        on: connection,
        library: library
      )
    }
    self.isQueryOnly = isQueryOnly
  }

  /// Restores the timeout and whether it had replaced the configured busy handler.
  mutating func restoreBusyTimeout(
    _ timeout: SQLiteBusyTimeout,
    handlerIsReplaced: Bool
  ) throws {
    var failure: (any Error)?
    if busyTimeout != timeout {
      // Reapplying the timeout replaces any busy handler a connection setup installed, which is
      // why it is only reapplied once it has actually changed.
      do {
        try setBusyTimeout(timeout)
      } catch {
        failure = error
      }
    }
    if isBusyHandlerReplaced && !handlerIsReplaced {
      // Installed after the timeout, exactly as the open did it, so the connection waits by the
      // configured handler again rather than by the timeout underneath it.
      let code = SQLiteBusyHandlerInstallation.install(
        on: connection,
        library: library,
        configuration: configuration
      )
      if code == SQLiteResultCode.ok.rawValue {
        isBusyHandlerReplaced = false
      } else {
        failure =
          failure
          ?? SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: nil)
      }
    }
    if let failure { throw failure }
  }

  /// Puts every changed setting back to its configured value.
  ///
  /// Every changed setting is attempted even after one fails, so one failure leaves no more
  /// behind than it has to. A setting that cannot be restored stays changed.
  ///
  /// - Throws: The first failure.
  mutating func restore() throws {
    var failure: (any Error)?
    do {
      try restoreBusyTimeout(configuredBusyTimeout, handlerIsReplaced: false)
    } catch {
      failure = error
    }
    if isForeignKeysEnabled != configuredForeignKeys || needsForeignKeysRestore {
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
}
