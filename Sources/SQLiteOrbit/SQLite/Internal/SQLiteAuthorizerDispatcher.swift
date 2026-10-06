enum SQLiteAuthorizationCode: Int32 {
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

struct SQLiteRawAuthorization {
  let actionCode: Int32
  let action: SQLiteAuthorizationCode?
  let firstArgument: String?
  let secondArgument: String?
  let schemaName: String?
  let sourceName: String?
}

/// Owns SQLite's single authorizer callback and multiplexes scoped handlers over it.
///
/// The dispatcher is confined to its connection's serial executor. Its callback is installed once
/// so internal recording handlers do not invalidate prepared statements. Application policy changes
/// explicitly invalidate the cache and advance the authorization generation.
final class SQLiteAuthorizerDispatcher {
  typealias Handler = (SQLiteRawAuthorization) -> SQLiteAuthorizationDecision

  private var handlers: [Handler] = []
  private var policy: SQLiteAuthorizationHandler?
  private var scopedPolicies: [SQLiteAuthorizationHandler] = []
  private var isUserAuthorizationSuspended = false
  private var requiresExecution = false
  private(set) var generation: UInt64 = 0
  var activeCursors = 0

  func setAuthorization(
    _ policy: SQLiteAuthorizationHandler?,
    using library: SQLiteLibrary,
    statements: SQLiteStatementCache
  ) throws {
    try checkPolicyChange(using: library)
    guard scopedPolicies.isEmpty else {
      throw SQLiteError(
        code: .misuse,
        message: "Cannot replace authorization inside an authorization scope"
      )
    }
    self.policy = policy
    policyDidChange(statements: statements)
  }

  func withAuthorization<Result: ~Copyable>(
    _ policy: @escaping SQLiteAuthorizationHandler,
    using library: SQLiteLibrary,
    statements: SQLiteStatementCache,
    perform operation: () throws -> Result
  ) throws -> Result {
    try checkPolicyChange(using: library)
    scopedPolicies.append(policy)
    policyDidChange(statements: statements)
    defer {
      scopedPolicies.removeLast()
      policyDidChange(statements: statements)
    }
    return try operation()
  }

  private func checkPolicyChange(using library: SQLiteLibrary) throws {
    guard library.authorizer != nil else {
      throw SQLiteFeatureUnavailableError(libraryName: library.name, feature: .authorizer)
    }
    guard activeCursors == 0 else {
      throw SQLiteError(
        code: .misuse,
        message: "Release outstanding cursors before changing authorization"
      )
    }
  }

  private func policyDidChange(statements: SQLiteStatementCache) {
    generation &+= 1
    statements.invalidateAuthorization()
  }

  /// Recovery must be able to roll back and restore settings even when application SQL is denied.
  func withoutUserAuthorization<Result: ~Copyable>(_ operation: () throws -> Result) rethrows
    -> Result
  {
    let previous = isUserAuthorizationSuspended
    isUserAuthorizationSuspended = true
    defer { isUserAuthorizationSuspended = previous }
    return try operation()
  }

  /// Silently ignoring a managed BEGIN, COMMIT, or setting would invalidate the driver's state.
  func requiringExecution<Result: ~Copyable>(_ operation: () throws -> Result) rethrows -> Result {
    let previous = requiresExecution
    requiresExecution = true
    defer { requiresExecution = previous }
    return try operation()
  }

  func install(
    on connection: OpaquePointer,
    using library: UnsafePointer<SQLiteLibrary>
  ) throws {
    guard let authorizer = library.pointee.authorizer else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    let code = authorizer.install(connection, Self.callback, context)
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(
        by: library.pointee,
        on: connection,
        code: code,
        sql: nil
      )
    }
  }

  func withHandler<Result: ~Copyable>(
    _ handler: @escaping Handler,
    perform operation: () throws -> Result
  ) rethrows -> Result {
    handlers.append(handler)
    defer { handlers.removeLast() }
    return try operation()
  }

  func recordingAuthorizations<Result>(
    during operation: () throws -> Result
  ) rethrows -> (result: Result, authorizations: [SQLiteRawAuthorization]) {
    var authorizations: [SQLiteRawAuthorization] = []
    let result = try withHandler(
      { authorization in
        authorizations.append(authorization)
        return .allow
      },
      perform: operation
    )
    return (result, authorizations)
  }

  private func authorize(_ authorization: SQLiteRawAuthorization) -> SQLiteAuthorizationDecision {
    var decision = SQLiteAuthorizationDecision.allow
    func combine(_ next: SQLiteAuthorizationDecision) {
      switch next {
      case .deny:
        decision = .deny
      case .ignore where decision == .allow:
        decision = .ignore
      case .allow, .ignore:
        break
      }
    }
    for handler in handlers { combine(handler(authorization)) }
    if !isUserAuthorizationSuspended {
      let request = SQLiteAuthorization(authorization)
      if let policy { combine(policy(request)) }
      for policy in scopedPolicies { combine(policy(request)) }
    }
    return requiresExecution && decision == .ignore ? .deny : decision
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
        SQLiteRawAuthorization(
          actionCode: actionCode,
          action: SQLiteAuthorizationCode(rawValue: actionCode),
          firstArgument: firstArgument.map(String.init(cString:)),
          secondArgument: secondArgument.map(String.init(cString:)),
          schemaName: schemaName.map(String.init(cString:)),
          sourceName: sourceName.map(String.init(cString:))
        )
      )
      .rawValue
  }
}
