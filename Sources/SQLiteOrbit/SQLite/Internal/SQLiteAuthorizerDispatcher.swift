enum SQLiteAuthorizationDecision: Int32 {
  case allow = 0
  case deny = 1
  case ignore = 2
}

struct SQLiteAuthorization {
  let actionCode: Int32
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

  func withHandler<Result>(
    _ handler: @escaping Handler,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    handlers.append(handler)
    defer { handlers.removeLast() }
    return try operation()
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
          actionCode: actionCode,
          firstArgument: firstArgument.map(String.init(cString:)),
          secondArgument: secondArgument.map(String.init(cString:)),
          schemaName: schemaName.map(String.init(cString:)),
          sourceName: sourceName.map(String.init(cString:))
        )
      )
      .rawValue
  }
}
