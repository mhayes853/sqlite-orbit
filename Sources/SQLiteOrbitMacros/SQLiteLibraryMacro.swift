import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct SQLiteLibraryMacro: ExpressionMacro {
  public static func expansion(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) throws -> ExprSyntax {
    var module: String?
    var includesEncryption = false

    for argument in node.arguments {
      switch argument.label?.text {
      case "module":
        guard
          let name = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue,
          name.isModuleName
        else {
          throw DiagnosticsError(
            diagnostics: [
              Diagnostic(
                node: argument.expression,
                message: MacroExpansionErrorMessage(
                  "'module' must be a string literal containing a Swift module name"
                )
              )
            ]
          )
        }
        module = name

      case "encryption":
        guard let literal = argument.expression.as(BooleanLiteralExprSyntax.self) else {
          throw DiagnosticsError(
            diagnostics: [
              Diagnostic(
                node: argument.expression,
                message: MacroExpansionErrorMessage("'encryption' must be a boolean literal")
              )
            ]
          )
        }
        includesEncryption = literal.literal.tokenKind == .keyword(.true)

      default:
        throw DiagnosticsError(
          diagnostics: [
            Diagnostic(
              node: argument,
              message: MacroExpansionErrorMessage(
                "expected only 'module:' and 'encryption:' arguments"
              )
            )
          ]
        )
      }
    }

    let qualifier = module.map { "\($0)." } ?? ""
    let encryption: ExprSyntax =
      if includesEncryption {
        "SQLiteLibrary.Encryption(key_v2: \(raw: qualifier)sqlite3_key_v2, rekey_v2: \(raw: qualifier)sqlite3_rekey_v2)"
      } else {
        "nil"
      }

    return """
      SQLiteLibrary(
        open_v2: \(raw: qualifier)sqlite3_open_v2,
        close_v2: \(raw: qualifier)sqlite3_close_v2,
        errmsg: \(raw: qualifier)sqlite3_errmsg,
        extended_errcode: \(raw: qualifier)sqlite3_extended_errcode,
        extended_result_codes: \(raw: qualifier)sqlite3_extended_result_codes,
        busy_timeout: \(raw: qualifier)sqlite3_busy_timeout,
        interrupt: \(raw: qualifier)sqlite3_interrupt,
        changes: \(raw: qualifier)sqlite3_changes,
        last_insert_rowid: \(raw: qualifier)sqlite3_last_insert_rowid,
        get_autocommit: \(raw: qualifier)sqlite3_get_autocommit,
        threadsafe: \(raw: qualifier)sqlite3_threadsafe,
        libversion_number: \(raw: qualifier)sqlite3_libversion_number,
        prepare_v3: \(raw: qualifier)sqlite3_prepare_v3,
        step: \(raw: qualifier)sqlite3_step,
        reset: \(raw: qualifier)sqlite3_reset,
        finalize: \(raw: qualifier)sqlite3_finalize,
        clear_bindings: \(raw: qualifier)sqlite3_clear_bindings,
        stmt_readonly: \(raw: qualifier)sqlite3_stmt_readonly,
        sql: \(raw: qualifier)sqlite3_sql,
        bind_parameter_count: \(raw: qualifier)sqlite3_bind_parameter_count,
        bind_null: \(raw: qualifier)sqlite3_bind_null,
        bind_int64: \(raw: qualifier)sqlite3_bind_int64,
        bind_double: \(raw: qualifier)sqlite3_bind_double,
        bind_text: {
          \(raw: qualifier)sqlite3_bind_text($0, $1, $2, $3, SQLiteLibrary.transientDestructor)
        },
        bind_blob: {
          \(raw: qualifier)sqlite3_bind_blob($0, $1, $2, $3, SQLiteLibrary.transientDestructor)
        },
        column_count: \(raw: qualifier)sqlite3_column_count,
        column_type: \(raw: qualifier)sqlite3_column_type,
        column_int64: \(raw: qualifier)sqlite3_column_int64,
        column_double: \(raw: qualifier)sqlite3_column_double,
        column_text: \(raw: qualifier)sqlite3_column_text,
        column_blob: \(raw: qualifier)sqlite3_column_blob,
        column_bytes: \(raw: qualifier)sqlite3_column_bytes,
        column_name: \(raw: qualifier)sqlite3_column_name,
        set_authorizer: \(raw: qualifier)sqlite3_set_authorizer,
        create_function_v2: \(raw: qualifier)sqlite3_create_function_v2,
        create_collation_v2: \(raw: qualifier)sqlite3_create_collation_v2,
        user_data: \(raw: qualifier)sqlite3_user_data,
        aggregate_context: \(raw: qualifier)sqlite3_aggregate_context,
        value_type: \(raw: qualifier)sqlite3_value_type,
        value_int64: \(raw: qualifier)sqlite3_value_int64,
        value_double: \(raw: qualifier)sqlite3_value_double,
        value_text: \(raw: qualifier)sqlite3_value_text,
        value_blob: \(raw: qualifier)sqlite3_value_blob,
        value_bytes: \(raw: qualifier)sqlite3_value_bytes,
        result_null: \(raw: qualifier)sqlite3_result_null,
        result_int64: \(raw: qualifier)sqlite3_result_int64,
        result_double: \(raw: qualifier)sqlite3_result_double,
        result_text: {
          \(raw: qualifier)sqlite3_result_text($0, $1, $2, SQLiteLibrary.transientDestructor)
        },
        result_blob: {
          \(raw: qualifier)sqlite3_result_blob($0, $1, $2, SQLiteLibrary.transientDestructor)
        },
        result_error: \(raw: qualifier)sqlite3_result_error,
        encryption: \(encryption)
      )
      """
  }
}

extension String {
  fileprivate var isModuleName: Bool {
    guard let first, first == "_" || first.isLetter else { return false }
    return dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }
}
