import MacroTesting
import SQLiteOrbitMacros
import Testing

@Suite(.macros(["sqliteLibrary": SQLiteLibraryMacro.self]))
struct SQLiteLibraryMacroTests {
  @Test
  func unqualifiedLibrary() {
    assertMacro {
      """
      let library = #sqliteLibrary()
      """
    } expansion: {
      """
      let library = SQLiteLibrary(
        open_v2: sqlite3_open_v2,
        close_v2: sqlite3_close_v2,
        errmsg: sqlite3_errmsg,
        extended_errcode: sqlite3_extended_errcode,
        extended_result_codes: sqlite3_extended_result_codes,
        busy_timeout: sqlite3_busy_timeout,
        interrupt: sqlite3_interrupt,
        changes: sqlite3_changes,
        last_insert_rowid: sqlite3_last_insert_rowid,
        get_autocommit: sqlite3_get_autocommit,
        threadsafe: sqlite3_threadsafe,
        libversion_number: sqlite3_libversion_number,
        prepare_v3: sqlite3_prepare_v3,
        step: sqlite3_step,
        reset: sqlite3_reset,
        finalize: sqlite3_finalize,
        clear_bindings: sqlite3_clear_bindings,
        stmt_readonly: sqlite3_stmt_readonly,
        sql: sqlite3_sql,
        bind_parameter_count: sqlite3_bind_parameter_count,
        bind_null: sqlite3_bind_null,
        bind_int64: sqlite3_bind_int64,
        bind_double: sqlite3_bind_double,
        bind_text: {
          sqlite3_bind_text($0, $1, $2, $3, SQLiteLibrary.transientDestructor)
        },
        bind_blob: {
          sqlite3_bind_blob($0, $1, $2, $3, SQLiteLibrary.transientDestructor)
        },
        column_count: sqlite3_column_count,
        column_type: sqlite3_column_type,
        column_int64: sqlite3_column_int64,
        column_double: sqlite3_column_double,
        column_text: sqlite3_column_text,
        column_blob: sqlite3_column_blob,
        column_bytes: sqlite3_column_bytes,
        column_name: sqlite3_column_name,
        set_authorizer: sqlite3_set_authorizer,
        create_function_v2: sqlite3_create_function_v2,
        create_collation_v2: sqlite3_create_collation_v2,
        user_data: sqlite3_user_data,
        aggregate_context: sqlite3_aggregate_context,
        value_type: sqlite3_value_type,
        value_int64: sqlite3_value_int64,
        value_double: sqlite3_value_double,
        value_text: sqlite3_value_text,
        value_blob: sqlite3_value_blob,
        value_bytes: sqlite3_value_bytes,
        result_null: sqlite3_result_null,
        result_int64: sqlite3_result_int64,
        result_double: sqlite3_result_double,
        result_text: {
          sqlite3_result_text($0, $1, $2, SQLiteLibrary.transientDestructor)
        },
        result_blob: {
          sqlite3_result_blob($0, $1, $2, SQLiteLibrary.transientDestructor)
        },
        result_error: sqlite3_result_error,
        encryption: nil
      )
      """
    }
  }

  @Test
  func qualifiedEncryptedLibrary() {
    assertMacro {
      """
      let library = #sqliteLibrary(module: "SQLCipher", encryption: true)
      """
    } expansion: {
      """
      let library = SQLiteLibrary(
        open_v2: SQLCipher.sqlite3_open_v2,
        close_v2: SQLCipher.sqlite3_close_v2,
        errmsg: SQLCipher.sqlite3_errmsg,
        extended_errcode: SQLCipher.sqlite3_extended_errcode,
        extended_result_codes: SQLCipher.sqlite3_extended_result_codes,
        busy_timeout: SQLCipher.sqlite3_busy_timeout,
        interrupt: SQLCipher.sqlite3_interrupt,
        changes: SQLCipher.sqlite3_changes,
        last_insert_rowid: SQLCipher.sqlite3_last_insert_rowid,
        get_autocommit: SQLCipher.sqlite3_get_autocommit,
        threadsafe: SQLCipher.sqlite3_threadsafe,
        libversion_number: SQLCipher.sqlite3_libversion_number,
        prepare_v3: SQLCipher.sqlite3_prepare_v3,
        step: SQLCipher.sqlite3_step,
        reset: SQLCipher.sqlite3_reset,
        finalize: SQLCipher.sqlite3_finalize,
        clear_bindings: SQLCipher.sqlite3_clear_bindings,
        stmt_readonly: SQLCipher.sqlite3_stmt_readonly,
        sql: SQLCipher.sqlite3_sql,
        bind_parameter_count: SQLCipher.sqlite3_bind_parameter_count,
        bind_null: SQLCipher.sqlite3_bind_null,
        bind_int64: SQLCipher.sqlite3_bind_int64,
        bind_double: SQLCipher.sqlite3_bind_double,
        bind_text: {
          SQLCipher.sqlite3_bind_text($0, $1, $2, $3, SQLiteLibrary.transientDestructor)
        },
        bind_blob: {
          SQLCipher.sqlite3_bind_blob($0, $1, $2, $3, SQLiteLibrary.transientDestructor)
        },
        column_count: SQLCipher.sqlite3_column_count,
        column_type: SQLCipher.sqlite3_column_type,
        column_int64: SQLCipher.sqlite3_column_int64,
        column_double: SQLCipher.sqlite3_column_double,
        column_text: SQLCipher.sqlite3_column_text,
        column_blob: SQLCipher.sqlite3_column_blob,
        column_bytes: SQLCipher.sqlite3_column_bytes,
        column_name: SQLCipher.sqlite3_column_name,
        set_authorizer: SQLCipher.sqlite3_set_authorizer,
        create_function_v2: SQLCipher.sqlite3_create_function_v2,
        create_collation_v2: SQLCipher.sqlite3_create_collation_v2,
        user_data: SQLCipher.sqlite3_user_data,
        aggregate_context: SQLCipher.sqlite3_aggregate_context,
        value_type: SQLCipher.sqlite3_value_type,
        value_int64: SQLCipher.sqlite3_value_int64,
        value_double: SQLCipher.sqlite3_value_double,
        value_text: SQLCipher.sqlite3_value_text,
        value_blob: SQLCipher.sqlite3_value_blob,
        value_bytes: SQLCipher.sqlite3_value_bytes,
        result_null: SQLCipher.sqlite3_result_null,
        result_int64: SQLCipher.sqlite3_result_int64,
        result_double: SQLCipher.sqlite3_result_double,
        result_text: {
          SQLCipher.sqlite3_result_text($0, $1, $2, SQLiteLibrary.transientDestructor)
        },
        result_blob: {
          SQLCipher.sqlite3_result_blob($0, $1, $2, SQLiteLibrary.transientDestructor)
        },
        result_error: SQLCipher.sqlite3_result_error,
        encryption: SQLiteLibrary.Encryption(key_v2: SQLCipher.sqlite3_key_v2, rekey_v2: SQLCipher.sqlite3_rekey_v2)
      )
      """
    }
  }

  @Test
  func moduleMustBeALiteralModuleName() {
    assertMacro {
      """
      let module = "SQLCipher"
      let library = #sqliteLibrary(module: module)
      """
    } diagnostics: {
      """
      let module = "SQLCipher"
      let library = #sqliteLibrary(module: module)
                                           ┬─────
                                           ╰─ 🛑 'module' must be a string literal containing a Swift module name
      """
    }
  }

  @Test
  func encryptionMustBeABooleanLiteral() {
    assertMacro {
      """
      let encrypted = true
      let library = #sqliteLibrary(encryption: encrypted)
      """
    } diagnostics: {
      """
      let encrypted = true
      let library = #sqliteLibrary(encryption: encrypted)
                                               ┬────────
                                               ╰─ 🛑 'encryption' must be a boolean literal
      """
    }
  }
}
