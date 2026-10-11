extension SQLiteConnectionAccess {
  /// Replaces this connection's persistent application policy, invalidating prepared statements.
  ///
  /// The change lasts for the connection's lifetime, including later lending calls. Pass `nil` to
  /// remove the application policy. The configured value is not restored when an access ends.
  /// This affects only this connection; use `SQLiteConfiguration.authorization` for every pool
  /// connection. Policies must not access their connection or change captured permission state.
  ///
  /// Throws if authorization is unavailable, cursors remain outstanding, or a scoped policy is
  /// active. The library's own access restrictions remain in force.
  public borrowing func setAuthorization(_ policy: SQLiteAuthorizationHandler?) throws {
    try authorizer.setAuthorization(policy, using: sqlite, statements: statements)
  }

  /// Adds an authorization policy for the synchronous operation, restoring the prior policies
  /// on return or throw. A denial from any active policy wins over allowances.
  ///
  /// Statements are invalidated on entry and exit. Release all outstanding cursors before entering
  /// a scope; cursors created inside it must be consumed inside it. No asynchronous work may escape
  /// the operation. The handler must not access this connection. Library rollback and restoration
  /// of temporary settings bypass application policies so errors can be cleaned up.
  ///
  /// Throws if authorization is unavailable or cursors remain outstanding, or if the operation
  /// throws. Returning `.ignore` has SQLite's action-specific semantics; it is not general denial.
  /// For required transaction control and driver settings, `.ignore` is treated as denial.
  public borrowing func withAuthorization<Result: ~Copyable>(
    _ policy: @escaping SQLiteAuthorizationHandler,
    perform operation: () throws -> Result
  ) throws -> Result {
    try authorizer.withAuthorization(
      policy,
      using: sqlite,
      statements: statements,
      perform: operation
    )
  }
}

extension SQLiteReadTransaction {
  /// Adds a synchronous authorization scope, composing with the connection policy and any outer
  /// scopes. Release outstanding cursors first. See `SQLiteConnectionAccess.withAuthorization`.
  public borrowing func withAuthorization<Result: ~Copyable>(
    _ policy: @escaping SQLiteAuthorizationHandler,
    perform operation: () throws -> Result
  ) throws -> Result {
    try access.withAuthorization(policy, perform: operation)
  }
}

extension SQLiteWriteTransaction {
  /// Adds a synchronous authorization scope, composing with the connection policy and any outer
  /// scopes. Release outstanding cursors first. See `SQLiteConnectionAccess.withAuthorization`.
  public borrowing func withAuthorization<Result: ~Copyable>(
    _ policy: @escaping SQLiteAuthorizationHandler,
    perform operation: () throws -> Result
  ) throws -> Result {
    try base.withAuthorization(policy, perform: operation)
  }
}

extension SQLiteReadConnection {
  /// Adds a synchronous authorization scope, composing with the connection policy and any outer
  /// scopes. Release outstanding cursors first. See `SQLiteConnectionAccess.withAuthorization`.
  public borrowing func withAuthorization<Result: ~Copyable>(
    _ policy: @escaping SQLiteAuthorizationHandler,
    perform operation: () throws -> Result
  ) throws -> Result {
    try base.withAuthorization(policy, perform: operation)
  }

  /// Replaces this connection's persistent policy. See `SQLiteConnectionAccess.setAuthorization`.
  public borrowing func setAuthorization(_ policy: SQLiteAuthorizationHandler?) throws {
    try base.access.setAuthorization(policy)
  }
}

extension SQLiteWriteConnection {
  /// Adds a synchronous authorization scope, composing with the connection policy and any outer
  /// scopes. Release outstanding cursors first. See `SQLiteConnectionAccess.withAuthorization`.
  public borrowing func withAuthorization<Result: ~Copyable>(
    _ policy: @escaping SQLiteAuthorizationHandler,
    perform operation: () throws -> Result
  ) throws -> Result {
    try base.withAuthorization(policy, perform: operation)
  }

  /// Replaces this connection's persistent policy. See `SQLiteConnectionAccess.setAuthorization`.
  public borrowing func setAuthorization(_ policy: SQLiteAuthorizationHandler?) throws {
    try base.base.access.setAuthorization(policy)
  }
}
