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
    // An API the build was not said to implement is left out, which is what makes its group `nil`.
    func group(_ api: API, _ expression: @autoclosure () -> ExprSyntax) -> ExprSyntax {
      apis.contains(api) ? expression() : "nil"
    }
    let callbacksArgument = labeledArgument("callbacks", functionCallbacks(qualifier: qualifier))
    let trustedSchema = group(
      .trustedSchema,
      """
      { connection, enabled in
        try connection.execute("PRAGMA trusted_schema = \\(raw: enabled ? 1 : 0)")
      }
      """
    )
    let authorizer = group(
      .authorizer,
      "SQLiteLibrary.Authorizer(install: \(raw: qualifier)sqlite3_set_authorizer)"
    )
    let busyHandler = group(
      .busyHandler,
      "SQLiteLibrary.BusyHandler(install: \(raw: qualifier)sqlite3_busy_handler)"
    )
    let scalarFunctions = group(
      .scalarFunctions,
      """
      SQLiteLibrary.ScalarFunctions(
        register: \(raw: qualifier)sqlite3_create_function_v2,
        \(callbacksArgument)
      )
      """
    )
    let aggregateFunctions = group(
      .aggregateFunctions,
      """
      SQLiteLibrary.AggregateFunctions(
        register: \(raw: qualifier)sqlite3_create_function_v2,
        context: \(raw: qualifier)sqlite3_aggregate_context,
        \(callbacksArgument)
      )
      """
    )
    let collation = group(
      .collations,
      "SQLiteLibrary.Collations(create: \(raw: qualifier)sqlite3_create_collation_v2)"
    )
    let encryption = group(
      .encryption,
      "SQLiteLibrary.Encryption(key: \(raw: qualifier)sqlite3_key_v2, rekey: \(raw: qualifier)sqlite3_rekey_v2)"
    )
    return """
      SQLiteLibrary(
        runtime: SQLiteLibrary.Runtime(
          threadsafe: \(raw: qualifier)sqlite3_threadsafe,
          versionNumber: \(raw: qualifier)sqlite3_libversion_number
        ),
        connections: SQLiteLibrary.Connections(
          open: \(raw: qualifier)sqlite3_open_v2,
          close: \(raw: qualifier)sqlite3_close_v2,
          errorMessage: \(raw: qualifier)sqlite3_errmsg,
          extendedErrorCode: \(raw: qualifier)sqlite3_extended_errcode,
          setExtendedResultCodes: \(raw: qualifier)sqlite3_extended_result_codes,
          setBusyTimeout: \(raw: qualifier)sqlite3_busy_timeout,
          interrupt: \(raw: qualifier)sqlite3_interrupt,
          changes: \(raw: qualifier)sqlite3_changes64,
          lastInsertedRowID: \(raw: qualifier)sqlite3_last_insert_rowid,
          isAutocommit: \(raw: qualifier)sqlite3_get_autocommit,
          walCheckpoint: \(raw: qualifier)sqlite3_wal_checkpoint_v2
        ),
        statements: SQLiteLibrary.Statements(
          preparation: SQLiteLibrary.StatementPreparation(
            prepare: \(raw: qualifier)sqlite3_prepare_v3
          ),
          execution: SQLiteLibrary.StatementExecution(
            step: \(raw: qualifier)sqlite3_step,
            reset: \(raw: qualifier)sqlite3_reset,
            finalize: \(raw: qualifier)sqlite3_finalize,
            clearBindings: \(raw: qualifier)sqlite3_clear_bindings
          ),
          inspection: SQLiteLibrary.StatementInspection(
            isReadOnly: \(raw: qualifier)sqlite3_stmt_readonly,
            sql: \(raw: qualifier)sqlite3_sql
          )
        ),
        bindings: SQLiteLibrary.Bindings(
          parameterCount: \(raw: qualifier)sqlite3_bind_parameter_count,
          null: \(raw: qualifier)sqlite3_bind_null,
          int64: \(raw: qualifier)sqlite3_bind_int64,
          double: \(raw: qualifier)sqlite3_bind_double,
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
          count: \(raw: qualifier)sqlite3_column_count,
          type: \(raw: qualifier)sqlite3_column_type,
          int64: \(raw: qualifier)sqlite3_column_int64,
          double: \(raw: qualifier)sqlite3_column_double,
          text: \(raw: qualifier)sqlite3_column_text,
          blob: \(raw: qualifier)sqlite3_column_blob,
          byteCount: \(raw: qualifier)sqlite3_column_bytes,
          name: \(raw: qualifier)sqlite3_column_name
        ),
        authorizer: \(authorizer),
        busyHandler: \(busyHandler),
        \(labeledArgument("trustedSchema", trustedSchema)),
        \(labeledArgument("scalarFunctions", scalarFunctions)),
        \(labeledArgument("aggregateFunctions", aggregateFunctions)),
        collations: \(collation),
        encryption: \(encryption)
      )
      """
  }

  private static func functionCallbacks(qualifier: String) -> ExprSyntax {
    return """
      SQLiteLibrary.FunctionCallbacks(
        context: SQLiteLibrary.FunctionCallbacks.Context(
          userData: \(raw: qualifier)sqlite3_user_data
        ),
        argument: SQLiteLibrary.FunctionCallbacks.Argument(
          type: \(raw: qualifier)sqlite3_value_type,
          int64: \(raw: qualifier)sqlite3_value_int64,
          double: \(raw: qualifier)sqlite3_value_double,
          text: \(raw: qualifier)sqlite3_value_text,
          blob: \(raw: qualifier)sqlite3_value_blob,
          byteCount: \(raw: qualifier)sqlite3_value_bytes
        ),
        result: SQLiteLibrary.FunctionCallbacks.Result(
          null: \(raw: qualifier)sqlite3_result_null,
          int64: \(raw: qualifier)sqlite3_result_int64,
          double: \(raw: qualifier)sqlite3_result_double,
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
          error: \(raw: qualifier)sqlite3_result_error
        )
      )
      """
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
