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
        runtime: SQLiteLibrary.Runtime(
          threadsafe: sqlite3_threadsafe,
          versionNumber: sqlite3_libversion_number
        ),
        connection: SQLiteLibrary.Connection(
          open: sqlite3_open_v2,
          close: sqlite3_close_v2,
          errorMessage: sqlite3_errmsg,
          extendedErrorCode: sqlite3_extended_errcode,
          setExtendedResultCodes: sqlite3_extended_result_codes,
          setBusyTimeout: sqlite3_busy_timeout,
          interrupt: sqlite3_interrupt,
          changes: sqlite3_changes,
          lastInsertedRowID: sqlite3_last_insert_rowid,
          isAutocommit: sqlite3_get_autocommit,
          trustedSchema: SQLiteLibrary.TrustedSchemaControl { connection, enabled in
        try connection.execute("PRAGMA trusted_schema = " + (enabled ? "1" : "0"))
          }
        ),
        statement: SQLiteLibrary.Statement(
          prepare: sqlite3_prepare_v3,
          step: sqlite3_step,
          reset: sqlite3_reset,
          finalize: sqlite3_finalize,
          clearBindings: sqlite3_clear_bindings,
          isReadOnly: sqlite3_stmt_readonly,
          sql: sqlite3_sql
        ),
        binding: SQLiteLibrary.Binding(
          parameterCount: sqlite3_bind_parameter_count,
          null: sqlite3_bind_null,
          int64: sqlite3_bind_int64,
          double: sqlite3_bind_double,
          text: {
            sqlite3_bind_text(
              $0, $1, $2, $3, SQLiteLibrary.transientDestructor
            )
          },
          blob: {
            sqlite3_bind_blob(
              $0, $1, $2, $3, SQLiteLibrary.transientDestructor
            )
          }
        ),
        column: SQLiteLibrary.Column(
          count: sqlite3_column_count,
          type: sqlite3_column_type,
          int64: sqlite3_column_int64,
          double: sqlite3_column_double,
          text: sqlite3_column_text,
          blob: sqlite3_column_blob,
          byteCount: sqlite3_column_bytes,
          name: sqlite3_column_name
        ),
        authorization: SQLiteLibrary.Authorization(install: sqlite3_set_authorizer),
        functions: SQLiteLibrary.Functions(
        registration: SQLiteLibrary.Functions.Registration(
          scalar: sqlite3_create_function_v2,
          aggregate: sqlite3_create_function_v2
        ),
        context: SQLiteLibrary.Functions.Context(
          userData: sqlite3_user_data,
          aggregate: sqlite3_aggregate_context
        ),
        argument: SQLiteLibrary.Functions.Argument(
          type: sqlite3_value_type,
          int64: sqlite3_value_int64,
          double: sqlite3_value_double,
          text: sqlite3_value_text,
          blob: sqlite3_value_blob,
          byteCount: sqlite3_value_bytes
        ),
        result: SQLiteLibrary.Functions.Result(
          null: sqlite3_result_null,
          int64: sqlite3_result_int64,
          double: sqlite3_result_double,
          text: {
            sqlite3_result_text(
              $0, $1, $2, SQLiteLibrary.transientDestructor
            )
          },
          blob: {
            sqlite3_result_blob(
              $0, $1, $2, SQLiteLibrary.transientDestructor
            )
          },
          error: sqlite3_result_error
        )
        ),
        collation: SQLiteLibrary.Collation(create: sqlite3_create_collation_v2),
        encryption: nil
      )
      """
    }
  }

  @Test
  func qualifiedEncryptedLibrary() {
    assertMacro {
      """
      let library = #sqliteLibrary(module: "SQLCipher", apis: .all)
      """
    } expansion: {
      """
      let library = SQLiteLibrary(
        runtime: SQLiteLibrary.Runtime(
          threadsafe: SQLCipher.sqlite3_threadsafe,
          versionNumber: SQLCipher.sqlite3_libversion_number
        ),
        connection: SQLiteLibrary.Connection(
          open: SQLCipher.sqlite3_open_v2,
          close: SQLCipher.sqlite3_close_v2,
          errorMessage: SQLCipher.sqlite3_errmsg,
          extendedErrorCode: SQLCipher.sqlite3_extended_errcode,
          setExtendedResultCodes: SQLCipher.sqlite3_extended_result_codes,
          setBusyTimeout: SQLCipher.sqlite3_busy_timeout,
          interrupt: SQLCipher.sqlite3_interrupt,
          changes: SQLCipher.sqlite3_changes,
          lastInsertedRowID: SQLCipher.sqlite3_last_insert_rowid,
          isAutocommit: SQLCipher.sqlite3_get_autocommit,
          trustedSchema: SQLiteLibrary.TrustedSchemaControl { connection, enabled in
        try connection.execute("PRAGMA trusted_schema = " + (enabled ? "1" : "0"))
          }
        ),
        statement: SQLiteLibrary.Statement(
          prepare: SQLCipher.sqlite3_prepare_v3,
          step: SQLCipher.sqlite3_step,
          reset: SQLCipher.sqlite3_reset,
          finalize: SQLCipher.sqlite3_finalize,
          clearBindings: SQLCipher.sqlite3_clear_bindings,
          isReadOnly: SQLCipher.sqlite3_stmt_readonly,
          sql: SQLCipher.sqlite3_sql
        ),
        binding: SQLiteLibrary.Binding(
          parameterCount: SQLCipher.sqlite3_bind_parameter_count,
          null: SQLCipher.sqlite3_bind_null,
          int64: SQLCipher.sqlite3_bind_int64,
          double: SQLCipher.sqlite3_bind_double,
          text: {
            SQLCipher.sqlite3_bind_text(
              $0, $1, $2, $3, SQLiteLibrary.transientDestructor
            )
          },
          blob: {
            SQLCipher.sqlite3_bind_blob(
              $0, $1, $2, $3, SQLiteLibrary.transientDestructor
            )
          }
        ),
        column: SQLiteLibrary.Column(
          count: SQLCipher.sqlite3_column_count,
          type: SQLCipher.sqlite3_column_type,
          int64: SQLCipher.sqlite3_column_int64,
          double: SQLCipher.sqlite3_column_double,
          text: SQLCipher.sqlite3_column_text,
          blob: SQLCipher.sqlite3_column_blob,
          byteCount: SQLCipher.sqlite3_column_bytes,
          name: SQLCipher.sqlite3_column_name
        ),
        authorization: SQLiteLibrary.Authorization(install: SQLCipher.sqlite3_set_authorizer),
        functions: SQLiteLibrary.Functions(
        registration: SQLiteLibrary.Functions.Registration(
          scalar: SQLCipher.sqlite3_create_function_v2,
          aggregate: SQLCipher.sqlite3_create_function_v2
        ),
        context: SQLiteLibrary.Functions.Context(
          userData: SQLCipher.sqlite3_user_data,
          aggregate: SQLCipher.sqlite3_aggregate_context
        ),
        argument: SQLiteLibrary.Functions.Argument(
          type: SQLCipher.sqlite3_value_type,
          int64: SQLCipher.sqlite3_value_int64,
          double: SQLCipher.sqlite3_value_double,
          text: SQLCipher.sqlite3_value_text,
          blob: SQLCipher.sqlite3_value_blob,
          byteCount: SQLCipher.sqlite3_value_bytes
        ),
        result: SQLiteLibrary.Functions.Result(
          null: SQLCipher.sqlite3_result_null,
          int64: SQLCipher.sqlite3_result_int64,
          double: SQLCipher.sqlite3_result_double,
          text: {
            SQLCipher.sqlite3_result_text(
              $0, $1, $2, SQLiteLibrary.transientDestructor
            )
          },
          blob: {
            SQLCipher.sqlite3_result_blob(
              $0, $1, $2, SQLiteLibrary.transientDestructor
            )
          },
          error: SQLCipher.sqlite3_result_error
        )
        ),
        collation: SQLiteLibrary.Collation(create: SQLCipher.sqlite3_create_collation_v2),
        encryption: SQLiteLibrary.Encryption(key: SQLCipher.sqlite3_key_v2, rekey: SQLCipher.sqlite3_rekey_v2)
      )
      """
    }
  }

  @Test
  func qualifiedLibraryWithOnlyRequiredAPIs() {
    assertMacro {
      """
      let library = #sqliteLibrary(module: "TursoSQLite3", apis: [])
      """
    } expansion: {
      """
      let library = SQLiteLibrary(
        runtime: SQLiteLibrary.Runtime(
          threadsafe: TursoSQLite3.sqlite3_threadsafe,
          versionNumber: TursoSQLite3.sqlite3_libversion_number
        ),
        connection: SQLiteLibrary.Connection(
          open: TursoSQLite3.sqlite3_open_v2,
          close: TursoSQLite3.sqlite3_close_v2,
          errorMessage: TursoSQLite3.sqlite3_errmsg,
          extendedErrorCode: TursoSQLite3.sqlite3_extended_errcode,
          setExtendedResultCodes: TursoSQLite3.sqlite3_extended_result_codes,
          setBusyTimeout: TursoSQLite3.sqlite3_busy_timeout,
          interrupt: TursoSQLite3.sqlite3_interrupt,
          changes: TursoSQLite3.sqlite3_changes,
          lastInsertedRowID: TursoSQLite3.sqlite3_last_insert_rowid,
          isAutocommit: TursoSQLite3.sqlite3_get_autocommit,
          trustedSchema: nil
        ),
        statement: SQLiteLibrary.Statement(
          prepare: TursoSQLite3.sqlite3_prepare_v3,
          step: TursoSQLite3.sqlite3_step,
          reset: TursoSQLite3.sqlite3_reset,
          finalize: TursoSQLite3.sqlite3_finalize,
          clearBindings: TursoSQLite3.sqlite3_clear_bindings,
          isReadOnly: TursoSQLite3.sqlite3_stmt_readonly,
          sql: TursoSQLite3.sqlite3_sql
        ),
        binding: SQLiteLibrary.Binding(
          parameterCount: TursoSQLite3.sqlite3_bind_parameter_count,
          null: TursoSQLite3.sqlite3_bind_null,
          int64: TursoSQLite3.sqlite3_bind_int64,
          double: TursoSQLite3.sqlite3_bind_double,
          text: {
            TursoSQLite3.sqlite3_bind_text(
              $0, $1, $2, $3, SQLiteLibrary.transientDestructor
            )
          },
          blob: {
            TursoSQLite3.sqlite3_bind_blob(
              $0, $1, $2, $3, SQLiteLibrary.transientDestructor
            )
          }
        ),
        column: SQLiteLibrary.Column(
          count: TursoSQLite3.sqlite3_column_count,
          type: TursoSQLite3.sqlite3_column_type,
          int64: TursoSQLite3.sqlite3_column_int64,
          double: TursoSQLite3.sqlite3_column_double,
          text: TursoSQLite3.sqlite3_column_text,
          blob: TursoSQLite3.sqlite3_column_blob,
          byteCount: TursoSQLite3.sqlite3_column_bytes,
          name: TursoSQLite3.sqlite3_column_name
        ),
        authorization: nil,
        functions: nil,
        collation: nil,
        encryption: nil
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
  func APIsMustBeAStaticOptionSetExpression() {
    assertMacro {
      """
      let apis: SQLiteLibrary.APIs = .standard
      let library = #sqliteLibrary(apis: apis)
      """
    } diagnostics: {
      """
      let apis: SQLiteLibrary.APIs = .standard
      let library = #sqliteLibrary(apis: apis)
                                         ┬───
                                         ╰─ 🛑 'apis' must be '.standard', '.all', '[]', or an array literal of API members
      """
    }
  }
}
