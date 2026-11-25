import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct SQLiteLibraryMacro: ExpressionMacro {
  private enum API: String, CaseIterable {
    case trustedSchema
    case authorizer
    case scalarFunctions
    case aggregateFunctions
    case collations
    case encryption
    case busyHandler
    case autoExtensions

    static let standard: Set<Self> = [
      .trustedSchema,
      .authorizer,
      .scalarFunctions,
      .aggregateFunctions,
      .collations,
      .busyHandler
    ]
  }

  public static func expansion(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) throws -> ExprSyntax {
    var module: String?
    var apis = API.standard

    for argument in node.arguments {
      switch argument.label?.text {
      case "module":
        guard
          let name = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue,
          name.isModuleName
        else {
          throw diagnostic(
            at: argument.expression,
            "'module' must be a string literal containing a Swift module name"
          )
        }
        module = name

      case "apis":
        apis = try parseAPIs(argument.expression)

      default:
        throw diagnostic(
          at: argument,
          "expected only 'module:' and 'apis:' arguments"
        )
      }
    }

    let qualifier = module.map { "\($0)." } ?? ""
    func function(_ name: String, arity: Int) -> String {
      entryPoint(name, arity: arity, qualifier: qualifier)
    }
    // An API the build was not said to implement is left out, which is what makes its group `nil`.
    func group(_ api: API, _ expression: @autoclosure () -> ExprSyntax) -> ExprSyntax {
      apis.contains(api) ? expression() : "nil"
    }
    let callbacksArgument = labeledArgument("callbacks", functionCallbacks(qualifier: qualifier))
    let trustedSchema = group(
      .trustedSchema,
      """
      { connection, enabled in
        try connection.execute(
          enabled ? "PRAGMA trusted_schema = 1" : "PRAGMA trusted_schema = 0"
        )
      }
      """
    )
    let authorizer = group(
      .authorizer,
      """
      SQLiteLibrary.Authorizer(
        install: \(raw: function("sqlite3_set_authorizer", arity: 3))
      )
      """
    )
    let busyHandler = group(
      .busyHandler,
      """
      SQLiteLibrary.BusyHandler(
        install: \(raw: function("sqlite3_busy_handler", arity: 3))
      )
      """
    )
    let scalarFunctions = group(
      .scalarFunctions,
      """
      SQLiteLibrary.ScalarFunctions(
        register: \(raw: function("sqlite3_create_function_v2", arity: 9)),
        \(callbacksArgument)
      )
      """
    )
    let aggregateFunctions = group(
      .aggregateFunctions,
      """
      SQLiteLibrary.AggregateFunctions(
        register: \(raw: function("sqlite3_create_function_v2", arity: 9)),
        context: \(raw: function("sqlite3_aggregate_context", arity: 2)),
        \(callbacksArgument)
      )
      """
    )
    let collation = group(
      .collations,
      """
      SQLiteLibrary.Collations(
        create: \(raw: function("sqlite3_create_collation_v2", arity: 6))
      )
      """
    )
    let encryption = group(
      .encryption,
      """
      SQLiteLibrary.Encryption(
        key: \(raw: function("sqlite3_key_v2", arity: 4)),
        rekey: \(raw: function("sqlite3_rekey_v2", arity: 4))
      )
      """
    )
    let extensions = group(
      .autoExtensions,
      """
      SQLiteLibrary.Extensions(
        autoExtensions: SQLiteLibrary.AutoExtensions(
          register: { \(raw: qualifier)sqlite3_auto_extension($0) },
          cancel: { \(raw: qualifier)sqlite3_cancel_auto_extension($0) }
        )
      )
      """
    )
    return """
      SQLiteLibrary(
        runtime: SQLiteLibrary.Runtime(
          threadsafe: \(raw: function("sqlite3_threadsafe", arity: 0)),
          versionNumber: \(raw: function("sqlite3_libversion_number", arity: 0))
        ),
        connections: SQLiteLibrary.Connections(
          open: \(raw: function("sqlite3_open_v2", arity: 4)),
          close: \(raw: function("sqlite3_close_v2", arity: 1)),
          errorMessage: \(raw: function("sqlite3_errmsg", arity: 1)),
          extendedErrorCode: \(raw: function("sqlite3_extended_errcode", arity: 1)),
          setExtendedResultCodes: \(raw: function("sqlite3_extended_result_codes", arity: 2)),
          setBusyTimeout: \(raw: function("sqlite3_busy_timeout", arity: 2)),
          interrupt: \(raw: function("sqlite3_interrupt", arity: 1)),
          changes: \(raw: function("sqlite3_changes64", arity: 1)),
          lastInsertedRowID: \(raw: function("sqlite3_last_insert_rowid", arity: 1)),
          isAutocommit: \(raw: function("sqlite3_get_autocommit", arity: 1)),
          walCheckpoint: \(raw: function("sqlite3_wal_checkpoint_v2", arity: 5))
        ),
        statements: SQLiteLibrary.Statements(
          preparation: SQLiteLibrary.StatementPreparation(
            prepare: \(raw: function("sqlite3_prepare_v3", arity: 6))
          ),
          execution: SQLiteLibrary.StatementExecution(
            step: \(raw: function("sqlite3_step", arity: 1)),
            reset: \(raw: function("sqlite3_reset", arity: 1)),
            finalize: \(raw: function("sqlite3_finalize", arity: 1)),
            clearBindings: \(raw: function("sqlite3_clear_bindings", arity: 1))
          ),
          inspection: SQLiteLibrary.StatementInspection(
            isReadOnly: \(raw: function("sqlite3_stmt_readonly", arity: 1)),
            sql: \(raw: function("sqlite3_sql", arity: 1))
          )
        ),
        bindings: SQLiteLibrary.Bindings(
          parameterCount: \(raw: function("sqlite3_bind_parameter_count", arity: 1)),
          null: \(raw: function("sqlite3_bind_null", arity: 2)),
          int64: \(raw: function("sqlite3_bind_int64", arity: 3)),
          double: \(raw: function("sqlite3_bind_double", arity: 3)),
          text: {
            \(raw: qualifier)sqlite3_bind_text(
              $0, $1, $2, $3, SQLiteLibrary.transientDestructor
            )
          },
          blob: {
            \(raw: qualifier)sqlite3_bind_blob(
              $0, $1, $2, $3, SQLiteLibrary.transientDestructor
            )
          }
        ),
        columns: SQLiteLibrary.Columns(
          count: \(raw: function("sqlite3_column_count", arity: 1)),
          type: \(raw: function("sqlite3_column_type", arity: 2)),
          int64: \(raw: function("sqlite3_column_int64", arity: 2)),
          double: \(raw: function("sqlite3_column_double", arity: 2)),
          text: \(raw: function("sqlite3_column_text", arity: 2)),
          blob: \(raw: function("sqlite3_column_blob", arity: 2)),
          byteCount: \(raw: function("sqlite3_column_bytes", arity: 2)),
          name: \(raw: function("sqlite3_column_name", arity: 2))
        ),
        \(labeledArgument("authorizer", authorizer)),
        \(labeledArgument("busyHandler", busyHandler)),
        \(labeledArgument("trustedSchema", trustedSchema)),
        \(labeledArgument("scalarFunctions", scalarFunctions)),
        \(labeledArgument("aggregateFunctions", aggregateFunctions)),
        \(labeledArgument("collations", collation)),
        \(labeledArgument("encryption", encryption)),
        \(labeledArgument("extensions", extensions))
      )
      """
  }

  private static func functionCallbacks(qualifier: String) -> ExprSyntax {
    func function(_ name: String, arity: Int) -> String {
      entryPoint(name, arity: arity, qualifier: qualifier)
    }
    return """
      SQLiteLibrary.FunctionCallbacks(
        context: SQLiteLibrary.FunctionCallbacks.Context(
          userData: \(raw: function("sqlite3_user_data", arity: 1))
        ),
        argument: SQLiteLibrary.FunctionCallbacks.Argument(
          type: \(raw: function("sqlite3_value_type", arity: 1)),
          int64: \(raw: function("sqlite3_value_int64", arity: 1)),
          double: \(raw: function("sqlite3_value_double", arity: 1)),
          text: \(raw: function("sqlite3_value_text", arity: 1)),
          blob: \(raw: function("sqlite3_value_blob", arity: 1)),
          byteCount: \(raw: function("sqlite3_value_bytes", arity: 1))
        ),
        result: SQLiteLibrary.FunctionCallbacks.Result(
          null: \(raw: function("sqlite3_result_null", arity: 1)),
          int64: \(raw: function("sqlite3_result_int64", arity: 2)),
          double: \(raw: function("sqlite3_result_double", arity: 2)),
          text: {
            \(raw: qualifier)sqlite3_result_text(
              $0, $1, $2, SQLiteLibrary.transientDestructor
            )
          },
          blob: {
            \(raw: qualifier)sqlite3_result_blob(
              $0, $1, $2, SQLiteLibrary.transientDestructor
            )
          },
          error: \(raw: function("sqlite3_result_error", arity: 3))
        )
      )
      """
  }

  /// A reference to a SQLite function that converts to a C function pointer.
  ///
  /// Swift forms a C function pointer only from an unqualified reference to a function or from a
  /// closure literal, so a function qualified by its module is called from a closure that captures
  /// nothing.
  private static func entryPoint(_ name: String, arity: Int, qualifier: String) -> String {
    guard !qualifier.isEmpty else { return name }
    let arguments = (0..<arity).map { "$\($0)" }.joined(separator: ", ")
    return "{ \(qualifier)\(name)(\(arguments)) }"
  }

  /// An argument built as syntax rather than interpolated as text.
  ///
  /// A multi-line expression interpolated into a call keeps the indentation it was written with,
  /// which is not the indentation it lands at. Handing the argument over as a node is what lets
  /// the printer lay it out where it goes.
  private static func labeledArgument(_ label: String, _ expression: ExprSyntax)
    -> LabeledExprSyntax
  {
    LabeledExprSyntax(
      label: .identifier(label),
      colon: .colonToken(trailingTrivia: .space),
      expression: expression
    )
  }

  private static func parseAPIs(_ expression: ExprSyntax) throws -> Set<API> {
    let invalidExpression = diagnostic(
      at: expression,
      "'apis' must be '.standard', '.all', '[]', or an array literal of API members"
    )
    if let member = expression.as(MemberAccessExprSyntax.self),
      member.base == nil, member.declName.argumentNames == nil
    {
      switch member.declName.baseName.text {
      case "standard": return API.standard
      case "all": return Set(API.allCases)
      default: throw invalidExpression
      }
    }
    guard let array = expression.as(ArrayExprSyntax.self) else {
      throw invalidExpression
    }

    var result: Set<API> = []
    for element in array.elements {
      guard let member = element.expression.as(MemberAccessExprSyntax.self),
        member.base == nil, member.declName.argumentNames == nil
      else {
        throw invalidExpression
      }
      let name = member.declName.baseName.text
      switch name {
      case "standard": result.formUnion(API.standard)
      case "all": result.formUnion(API.allCases)
      default:
        guard let api = API(rawValue: name) else {
          throw diagnostic(at: expression, "unknown SQLite library API '.\(name)'")
        }
        result.insert(api)
      }
    }
    return result
  }

  private static func diagnostic(
    at node: some SyntaxProtocol,
    _ message: String
  ) -> DiagnosticsError {
    DiagnosticsError(
      diagnostics: [Diagnostic(node: node, message: MacroExpansionErrorMessage(message))]
    )
  }
}

extension String {
  fileprivate var isModuleName: Bool {
    guard let first, first == "_" || first.isLetter else { return false }
    return dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }
}
