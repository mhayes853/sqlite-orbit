/// How SQLite should handle an action while preparing a statement.
public enum SQLiteAuthorizationDecision: Int32, Hashable, Sendable {
  /// Permits the action.
  case allow = 0

  /// Rejects the statement with an authorization error.
  case deny = 1

  /// Applies SQLite's action-specific ignore behavior while continuing preparation.
  ///
  /// Ignoring a column read substitutes SQL `NULL`. Ignoring a delete disables SQLite's truncate
  /// optimization; the rows are still deleted individually. It does not generally mean that the
  /// statement or its side effects are skipped.
  case ignore = 2
}

/// Decides whether a statement's action is allowed while SQLite prepares it.
///
/// The handler must not execute SQL or otherwise modify the connection that invoked it.
public typealias SQLiteAuthorizationHandler =
  @Sendable (SQLiteAuthorization) -> SQLiteAuthorizationDecision

/// One action SQLite authorizes while preparing or automatically repreparing a statement.
public struct SQLiteAuthorization: Hashable, Sendable {
  /// The action and its operation-specific details.
  public let action: SQLiteAuthorizationAction

  /// The affected database schema, when SQLite supplies one.
  public let schemaName: String?

  /// The innermost trigger or view responsible for the action, or `nil` for top-level SQL.
  public let sourceName: String?

  /// Creates an authorization event with SQLite's identifier spellings unchanged.
  public init(
    action: SQLiteAuthorizationAction,
    schemaName: String? = nil,
    sourceName: String? = nil
  ) {
    self.action = action
    self.schemaName = schemaName
    self.sourceName = sourceName
  }

  init(_ raw: SQLiteRawAuthorization) {
    let first = raw.firstArgument
    let second = raw.secondArgument
    let action: SQLiteAuthorizationAction =
      switch raw.action {
      case .createIndex: .createIndex(index: first, table: second)
      case .createTable: .createTable(table: first)
      case .createTemporaryIndex: .createTemporaryIndex(index: first, table: second)
      case .createTemporaryTable: .createTemporaryTable(table: first)
      case .createTemporaryTrigger: .createTemporaryTrigger(trigger: first, table: second)
      case .createTemporaryView: .createTemporaryView(view: first)
      case .createTrigger: .createTrigger(trigger: first, table: second)
      case .createView: .createView(view: first)
      case .delete: .delete(table: first)
      case .dropIndex: .dropIndex(index: first, table: second)
      case .dropTable: .dropTable(table: first)
      case .dropTemporaryIndex: .dropTemporaryIndex(index: first, table: second)
      case .dropTemporaryTable: .dropTemporaryTable(table: first)
      case .dropTemporaryTrigger: .dropTemporaryTrigger(trigger: first, table: second)
      case .dropTemporaryView: .dropTemporaryView(view: first)
      case .dropTrigger: .dropTrigger(trigger: first, table: second)
      case .dropView: .dropView(view: first)
      case .insert: .insert(table: first)
      case .pragma: .pragma(name: first, value: second)
      case .read: .read(table: first, column: second)
      case .select: .select
      case .transaction: .transaction(operation: first)
      case .update: .update(table: first, column: second)
      case .attach: .attach(filename: first)
      case .detach: .detach(schema: first)
      case .alterTable: .alterTable(schema: first, table: second)
      case .reindex: .reindex(index: first)
      case .analyze: .analyze(table: first)
      case .createVirtualTable: .createVirtualTable(table: first, module: second)
      case .dropVirtualTable: .dropVirtualTable(table: first, module: second)
      case .function: .function(name: second)
      case .savepoint: .savepoint(operation: first, name: second)
      case .recursive: .recursive
      case nil:
        .unknown(code: raw.actionCode, firstArgument: first, secondArgument: second)
      }
    self.init(action: action, schemaName: raw.schemaName, sourceName: raw.sourceName)
  }
}

/// The semantic action described by SQLite's authorizer callback.
///
/// Payloads are optional because SQLite may supply `NULL` for any callback argument. A column
/// name can also be empty when a query accesses a table without reading a particular column.
public enum SQLiteAuthorizationAction: Hashable, Sendable {
  case createIndex(index: String?, table: String?)
  case createTable(table: String?)
  case createTemporaryIndex(index: String?, table: String?)
  case createTemporaryTable(table: String?)
  case createTemporaryTrigger(trigger: String?, table: String?)
  case createTemporaryView(view: String?)
  case createTrigger(trigger: String?, table: String?)
  case createView(view: String?)
  case delete(table: String?)
  case dropIndex(index: String?, table: String?)
  case dropTable(table: String?)
  case dropTemporaryIndex(index: String?, table: String?)
  case dropTemporaryTable(table: String?)
  case dropTemporaryTrigger(trigger: String?, table: String?)
  case dropTemporaryView(view: String?)
  case dropTrigger(trigger: String?, table: String?)
  case dropView(view: String?)
  case insert(table: String?)
  case pragma(name: String?, value: String?)
  case read(table: String?, column: String?)
  case select
  case transaction(operation: String?)
  case update(table: String?, column: String?)
  case attach(filename: String?)
  case detach(schema: String?)
  case alterTable(schema: String?, table: String?)
  case reindex(index: String?)
  case analyze(table: String?)
  case createVirtualTable(table: String?, module: String?)
  case dropVirtualTable(table: String?, module: String?)
  case function(name: String?)
  case savepoint(operation: String?, name: String?)
  case recursive
  case unknown(code: Int32, firstArgument: String?, secondArgument: String?)
}
