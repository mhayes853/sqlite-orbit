enum SQLiteAuthorizationDecision: Int32 {
  case allow = 0
  case deny = 1
  case ignore = 2
}

enum SQLiteAuthorizationAction: Int32 {
  case createIndex = 1
  case createTable = 2
  case createTemporaryIndex = 3
  case createTemporaryTable = 4
  case createTemporaryTrigger = 5
  case createTemporaryView = 6
  case createTrigger = 7
  case createView = 8
  case delete = 9
  case dropIndex = 10
  case dropTable = 11
  case dropTemporaryIndex = 12
  case dropTemporaryTable = 13
  case dropTemporaryTrigger = 14
  case dropTemporaryView = 15
  case dropTrigger = 16
  case dropView = 17
  case insert = 18
  case pragma = 19
  case read = 20
  case select = 21
  case transaction = 22
  case update = 23
  case attach = 24
  case detach = 25
  case alterTable = 26
  case reindex = 27
  case analyze = 28
  case createVirtualTable = 29
  case dropVirtualTable = 30
  case function = 31
  case savepoint = 32
  case recursive = 33
}

struct SQLiteAuthorization {
  let action: SQLiteAuthorizationAction?
  let firstArgument: String?
  let secondArgument: String?
  let schemaName: String?
  let sourceName: String?
}

/// Owns SQLite's single authorizer callback and multiplexes scoped handlers over it.
///
/// The dispatcher is confined to its connection's serial executor. Its callback is installed once
/// so adding a handler does not invalidate already-prepared statements.
final class SQLiteAuthorizerDispatcher {
  typealias Handler = (SQLiteAuthorization) -> SQLiteAuthorizationDecision

  private var handlers: [Handler] = []

  func install(
    on connection: OpaquePointer,
    using library: UnsafePointer<SQLiteLibrary>
  ) throws {
    guard library.pointee.capabilities.contains(.statementAuthorizer) else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    let code = library.pointee.set_authorizer(connection, Self.callback, context)
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(
        by: library.pointee,
        on: connection,
        code: code,
        sql: nil
      )
    }
  }

  private func withHandler<Result>(
    _ handler: @escaping Handler,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    handlers.append(handler)
    defer { handlers.removeLast() }
    return try operation()
  }

  func recordingAuthorizations<Result>(
    during operation: () throws -> Result
  ) rethrows -> (result: Result, authorizations: [SQLiteAuthorization]) {
    var authorizations: [SQLiteAuthorization] = []
    let result = try withHandler(
      { authorization in
        authorizations.append(authorization)
        return .allow
      },
      perform: operation
    )
    return (result, authorizations)
  }

  private func authorize(_ authorization: SQLiteAuthorization) -> SQLiteAuthorizationDecision {
    var decision = SQLiteAuthorizationDecision.allow
    for handler in handlers {
      switch handler(authorization) {
      case .deny:
        decision = .deny
      case .ignore where decision == .allow:
        decision = .ignore
      case .allow, .ignore:
        break
      }
    }
    return decision
  }

  private static let callback: SQLiteAuthorizerCallback = {
    context,
    actionCode,
    firstArgument,
    secondArgument,
    schemaName,
    sourceName in
    guard let context else { return SQLiteAuthorizationDecision.allow.rawValue }
    let dispatcher = Unmanaged<SQLiteAuthorizerDispatcher>
      .fromOpaque(context)
      .takeUnretainedValue()
    return
      dispatcher.authorize(
        SQLiteAuthorization(
          action: SQLiteAuthorizationAction(rawValue: actionCode),
          firstArgument: firstArgument.map(String.init(cString:)),
          secondArgument: secondArgument.map(String.init(cString:)),
          schemaName: schemaName.map(String.init(cString:)),
          sourceName: sourceName.map(String.init(cString:))
        )
      )
      .rawValue
  }
}
