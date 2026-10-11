/// The settings an access may change on a connection, each kept beside the value the connection's
/// configuration gave it.
///
/// A setting counts as changed for as long as the value in effect on the connection differs from
/// its configured one. The handle restores every changed setting when an access ends and again,
/// for whatever could not be restored then, before the next access begins, so no access runs
/// under a setting an earlier one left behind. Only changes made through here are known: a raw
/// `PRAGMA` or a busy handler installed through the raw library is not tracked.
///
/// The handle keeps this in storage of its own rather than inline, since the handle is only ever
/// borrowed and the settings still have to change.
struct SQLiteConnectionSettings: ~Copyable {
  private let library: UnsafePointer<SQLiteLibrary>
  private let connection: OpaquePointer
  private let authorizer: SQLiteAuthorizerDispatcher
  private let statements: SQLiteStatementCache
  private let busyHandler = SQLiteBusyHandlerInstallation()

  private let configuredBusyPolicy: SQLiteBusyPolicy
  private let configuredForeignKeys: Bool

  /// The busy policy in effect on the connection.
  private(set) var busyPolicy: SQLiteBusyPolicy

  // A policy holds a closure, so whether the one in effect is the configured one is tracked rather
  // than compared. Reapplying the configured policy when it is already in effect would replace a
  // busy handler a connection setup installed, so it is only reapplied after a change.
  private(set) var isBusyPolicyConfigured = true

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
    configuration: SQLiteConfiguration
  ) {
    self.library = library
    self.connection = connection
    self.authorizer = authorizer
    self.statements = statements
    self.configuredBusyPolicy = configuration.busyPolicy
    self.configuredForeignKeys = configuration.isForeignKeysEnabled
    self.busyPolicy = configuration.busyPolicy
    self.isForeignKeysEnabled = configuration.isForeignKeysEnabled
  }

  /// Applies the configured busy policy, as a connection does once when it is opened.
  mutating func applyConfiguredBusyPolicy() throws {
    try apply(configuredBusyPolicy)
    isBusyPolicyConfigured = true
  }

  /// Applies `policy` until the access ends. The policy in effect is unchanged if applying fails.
  mutating func setBusyPolicy(_ policy: SQLiteBusyPolicy) throws {
    try apply(policy)
    isBusyPolicyConfigured = false
  }

  /// Puts back a policy saved before a scoped change, along with whether it was the configured
  /// one.
  mutating func restoreBusyPolicy(_ policy: SQLiteBusyPolicy, isConfigured: Bool) throws {
    try apply(policy)
    isBusyPolicyConfigured = isConfigured
  }

  private mutating func apply(_ policy: SQLiteBusyPolicy) throws {
    switch policy {
    case .handler(let handler):
      try busyHandler.install(handler, on: connection, library: library)
    case .timeout, .waitIndefinitely:
      let milliseconds = policy.timeoutMilliseconds ?? 0
      let code = library.pointee.connections.setBusyTimeout(connection, milliseconds)
      guard code == SQLiteResultCode.ok.rawValue else {
        throw SQLiteError.reported(by: library.pointee, on: connection, code: code, sql: nil)
      }
    }
    busyPolicy = policy
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

  /// Puts every changed setting back to its configured value.
  ///
  /// Every changed setting is attempted even after one fails, so one failure leaves no more
  /// behind than it has to. A setting that cannot be restored stays changed.
  ///
  /// - Throws: The first failure.
  mutating func restore() throws {
    var failure: (any Error)?
    if !isBusyPolicyConfigured {
      do {
        try applyConfiguredBusyPolicy()
      } catch {
        failure = error
      }
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
