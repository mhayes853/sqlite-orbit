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

    static let standard: Set<Self> = [
      .trustedSchema,
      .authorizer,
      .scalarFunctions,
      .aggregateFunctions,
      .collations
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
        do {
          apis = try parseAPIs(argument.expression)
        } catch let message as MacroExpansionErrorMessage {
          throw DiagnosticsError(
            diagnostics: [Diagnostic(node: argument.expression, message: message)]
          )
        }

      default:
        throw diagnostic(
          at: argument,
          "expected only 'module:' and 'apis:' arguments"
        )
      }
    }

    let qualifier = module.map { "\($0)." } ?? ""
    let trustedSchema: ExprSyntax =
      if apis.contains(.trustedSchema) {
        """
        { connection, enabled in
          try connection.execute("PRAGMA trusted_schema = \\(raw: enabled ? 1 : 0)")
        }
        """
      } else {
        "nil"
      }
    let authorizer: ExprSyntax =
      if apis.contains(.authorizer) {
        "SQLiteLibrary.Authorizer(install: \(raw: qualifier)sqlite3_set_authorizer)"
      } else {
        "nil"
      }
    let callbacks = functionCallbacks(qualifier: qualifier)
    let callbacksArgument = labeledArgument("callbacks", callbacks)
    let scalarFunctions: ExprSyntax =
      if apis.contains(.scalarFunctions) {
        """
        SQLiteLibrary.ScalarFunctions(
          register: \(raw: qualifier)sqlite3_create_function_v2,
          \(callbacksArgument)
        )
        """
      } else {
        "nil"
      }
    let aggregateFunctions: ExprSyntax =
      if apis.contains(.aggregateFunctions) {
        """
        SQLiteLibrary.AggregateFunctions(
          register: \(raw: qualifier)sqlite3_create_function_v2,
          context: \(raw: qualifier)sqlite3_aggregate_context,
          \(callbacksArgument)
        )
        """
      } else {
        "nil"
      }
    let collation: ExprSyntax =
      if apis.contains(.collations) {
        "SQLiteLibrary.Collations(create: \(raw: qualifier)sqlite3_create_collation_v2)"
      } else {
        "nil"
      }
    let encryption: ExprSyntax =
      if apis.contains(.encryption) {
        "SQLiteLibrary.Encryption(key: \(raw: qualifier)sqlite3_key_v2, rekey: \(raw: qualifier)sqlite3_rekey_v2)"
      } else {
        "nil"
      }
    let trustedSchemaArgument = labeledArgument("trustedSchema", trustedSchema)
    let scalarFunctionsArgument = labeledArgument("scalarFunctions", scalarFunctions)
    let aggregateFunctionsArgument = labeledArgument("aggregateFunctions", aggregateFunctions)

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
          changes: \(raw: qualifier)sqlite3_changes,
          lastInsertedRowID: \(raw: qualifier)sqlite3_last_insert_rowid,
          isAutocommit: \(raw: qualifier)sqlite3_get_autocommit
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
        \(trustedSchemaArgument),
        \(scalarFunctionsArgument),
        \(aggregateFunctionsArgument),
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
    let source = expression.trimmedDescription.filter { !$0.isWhitespace }
    if source == ".standard" { return API.standard }
    if source == ".all" { return Set(API.allCases) }
    guard source.first == "[", source.last == "]" else {
      throw MacroExpansionErrorMessage(
        "'apis' must be '.standard', '.all', '[]', or an array literal of API members"
      )
    }

    let contents = source.dropFirst().dropLast()
    guard !contents.isEmpty else { return [] }
    var result: Set<API> = []
    for component in contents.split(separator: ",") {
      let member = component.drop(while: { $0 == "." })
      if member == "standard" {
        result.formUnion(API.standard)
      } else if member == "all" {
        result.formUnion(API.allCases)
      } else if let api = API(rawValue: String(member)) {
        result.insert(api)
      } else {
        throw MacroExpansionErrorMessage("unknown SQLite library API '.\(member)'")
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
