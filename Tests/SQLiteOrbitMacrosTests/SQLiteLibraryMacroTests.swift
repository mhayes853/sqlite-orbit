import MacroTesting
import SQLiteOrbitMacros
import Testing

@Suite(.macros(["sqliteLibrary": SQLiteLibraryMacro.self], indentationWidth: .spaces(2)))
struct SQLiteLibraryMacroTests {
  @Test(arguments: [
    "",
    "apis: . /* defaults */ standard",
    "apis: [.standard, /* trailing comment */]",
    "apis: [.trustedSchema, .authorizer, .scalarFunctions, .aggregateFunctions, .collations,"
      + " .busyHandler]"
  ])
  func unqualifiedLibrary(arguments: String) {
    assertMacro {
      """
      let library = #sqliteLibrary(\(arguments))
      """
    } expansion: {
      """
      let library = SQLiteLibrary(
        runtime: SQLiteLibrary.Runtime(
          threadsafe: sqlite3_threadsafe,
          versionNumber: sqlite3_libversion_number
        ),
        connections: SQLiteLibrary.Connections(
          open: sqlite3_open_v2,
          close: sqlite3_close_v2,
          errorMessage: sqlite3_errmsg,
          extendedErrorCode: sqlite3_extended_errcode,
          setExtendedResultCodes: sqlite3_extended_result_codes,
          setBusyTimeout: sqlite3_busy_timeout,
          interrupt: sqlite3_interrupt,
          changes: sqlite3_changes64,
          lastInsertedRowID: sqlite3_last_insert_rowid,
          isAutocommit: sqlite3_get_autocommit,
          walCheckpoint: sqlite3_wal_checkpoint_v2
        ),
        statements: SQLiteLibrary.Statements(
          preparation: SQLiteLibrary.StatementPreparation(
            prepare: sqlite3_prepare_v3
          ),
          execution: SQLiteLibrary.StatementExecution(
            step: sqlite3_step,
            reset: sqlite3_reset,
            finalize: sqlite3_finalize,
            clearBindings: sqlite3_clear_bindings
          ),
          inspection: SQLiteLibrary.StatementInspection(
            isReadOnly: sqlite3_stmt_readonly,
            sql: sqlite3_sql
          )
        ),
        bindings: SQLiteLibrary.Bindings(
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
        columns: SQLiteLibrary.Columns(
          count: sqlite3_column_count,
          type: sqlite3_column_type,
          int64: sqlite3_column_int64,
          double: sqlite3_column_double,
          text: sqlite3_column_text,
          blob: sqlite3_column_blob,
          byteCount: sqlite3_column_bytes,
          name: sqlite3_column_name
        ),
        authorizer: SQLiteLibrary.Authorizer(
          install: sqlite3_set_authorizer
        ),
        busyHandler: SQLiteLibrary.BusyHandler(
          install: sqlite3_busy_handler
        ),
        trustedSchema: { connection, enabled in
          try connection.execute(
            enabled ? "PRAGMA trusted_schema = 1" : "PRAGMA trusted_schema = 0"
          )
        },
        scalarFunctions: SQLiteLibrary.ScalarFunctions(
          register: sqlite3_create_function_v2,
          callbacks: SQLiteLibrary.FunctionCallbacks(
            context: SQLiteLibrary.FunctionCallbacks.Context(
              userData: sqlite3_user_data
            ),
            argument: SQLiteLibrary.FunctionCallbacks.Argument(
              type: sqlite3_value_type,
              int64: sqlite3_value_int64,
              double: sqlite3_value_double,
              text: sqlite3_value_text,
              blob: sqlite3_value_blob,
              byteCount: sqlite3_value_bytes
            ),
            result: SQLiteLibrary.FunctionCallbacks.Result(
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
          )
        ),
        aggregateFunctions: SQLiteLibrary.AggregateFunctions(
          register: sqlite3_create_function_v2,
          context: sqlite3_aggregate_context,
          callbacks: SQLiteLibrary.FunctionCallbacks(
            context: SQLiteLibrary.FunctionCallbacks.Context(
              userData: sqlite3_user_data
            ),
            argument: SQLiteLibrary.FunctionCallbacks.Argument(
              type: sqlite3_value_type,
              int64: sqlite3_value_int64,
              double: sqlite3_value_double,
              text: sqlite3_value_text,
              blob: sqlite3_value_blob,
              byteCount: sqlite3_value_bytes
            ),
            result: SQLiteLibrary.FunctionCallbacks.Result(
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
          )
        ),
        collations: SQLiteLibrary.Collations(
          create: sqlite3_create_collation_v2
        ),
        encryption: nil,
        extensions: nil
      )
      """
    }
  }

  @Test(arguments: [
    ("[.standard, .encryption]", false),
    (".all", true),
    ("[.standard, .encryption, .autoExtensions]", true)
  ])
  func qualifiedEncryptedLibrary(apis: String, includesAutoExtensions: Bool) {
    let extensions =
      includesAutoExtensions
      ? """
      SQLiteLibrary.Extensions(
          autoExtensions: SQLiteLibrary.AutoExtensions(
            register: {
              SQLCipher.sqlite3_auto_extension($0)
            },
            cancel: {
              SQLCipher.sqlite3_cancel_auto_extension($0)
            }
          )
        )
      """ : "nil"
    assertMacro {
      """
      let library = #sqliteLibrary(module: "SQLCipher", apis: \(apis))
      """
    } expansion: {
      #"""
      let library = SQLiteLibrary(
        runtime: SQLiteLibrary.Runtime(
          threadsafe: {
            SQLCipher.sqlite3_threadsafe()
          },
          versionNumber: {
            SQLCipher.sqlite3_libversion_number()
          }
        ),
        connections: SQLiteLibrary.Connections(
          open: {
            SQLCipher.sqlite3_open_v2($0, $1, $2, $3)
          },
          close: {
            SQLCipher.sqlite3_close_v2($0)
          },
          errorMessage: {
            SQLCipher.sqlite3_errmsg($0)
          },
          extendedErrorCode: {
            SQLCipher.sqlite3_extended_errcode($0)
          },
          setExtendedResultCodes: {
            SQLCipher.sqlite3_extended_result_codes($0, $1)
          },
          setBusyTimeout: {
            SQLCipher.sqlite3_busy_timeout($0, $1)
          },
          interrupt: {
            SQLCipher.sqlite3_interrupt($0)
          },
          changes: {
            SQLCipher.sqlite3_changes64($0)
          },
          lastInsertedRowID: {
            SQLCipher.sqlite3_last_insert_rowid($0)
          },
          isAutocommit: {
            SQLCipher.sqlite3_get_autocommit($0)
          },
          walCheckpoint: {
            SQLCipher.sqlite3_wal_checkpoint_v2($0, $1, $2, $3, $4)
          }
        ),
        statements: SQLiteLibrary.Statements(
          preparation: SQLiteLibrary.StatementPreparation(
            prepare: {
              SQLCipher.sqlite3_prepare_v3($0, $1, $2, $3, $4, $5)
            }
          ),
          execution: SQLiteLibrary.StatementExecution(
            step: {
              SQLCipher.sqlite3_step($0)
            },
            reset: {
              SQLCipher.sqlite3_reset($0)
            },
            finalize: {
              SQLCipher.sqlite3_finalize($0)
            },
            clearBindings: {
              SQLCipher.sqlite3_clear_bindings($0)
            }
          ),
          inspection: SQLiteLibrary.StatementInspection(
            isReadOnly: {
              SQLCipher.sqlite3_stmt_readonly($0)
            },
            sql: {
              SQLCipher.sqlite3_sql($0)
            }
          )
        ),
        bindings: SQLiteLibrary.Bindings(
          parameterCount: {
            SQLCipher.sqlite3_bind_parameter_count($0)
          },
          null: {
            SQLCipher.sqlite3_bind_null($0, $1)
          },
          int64: {
            SQLCipher.sqlite3_bind_int64($0, $1, $2)
          },
          double: {
            SQLCipher.sqlite3_bind_double($0, $1, $2)
          },
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
        columns: SQLiteLibrary.Columns(
          count: {
            SQLCipher.sqlite3_column_count($0)
          },
          type: {
            SQLCipher.sqlite3_column_type($0, $1)
          },
          int64: {
            SQLCipher.sqlite3_column_int64($0, $1)
          },
          double: {
            SQLCipher.sqlite3_column_double($0, $1)
          },
          text: {
            SQLCipher.sqlite3_column_text($0, $1)
          },
          blob: {
            SQLCipher.sqlite3_column_blob($0, $1)
          },
          byteCount: {
            SQLCipher.sqlite3_column_bytes($0, $1)
          },
          name: {
            SQLCipher.sqlite3_column_name($0, $1)
          }
        ),
        authorizer: SQLiteLibrary.Authorizer(
          install: {
            SQLCipher.sqlite3_set_authorizer($0, $1, $2)
          }
        ),
        busyHandler: SQLiteLibrary.BusyHandler(
          install: {
            SQLCipher.sqlite3_busy_handler($0, $1, $2)
          }
        ),
        trustedSchema: { connection, enabled in
          try connection.execute(
            enabled ? "PRAGMA trusted_schema = 1" : "PRAGMA trusted_schema = 0"
          )
        },
        scalarFunctions: SQLiteLibrary.ScalarFunctions(
          register: {
            SQLCipher.sqlite3_create_function_v2($0, $1, $2, $3, $4, $5, $6, $7, $8)
          },
          callbacks: SQLiteLibrary.FunctionCallbacks(
            context: SQLiteLibrary.FunctionCallbacks.Context(
              userData: {
                SQLCipher.sqlite3_user_data($0)
              }
            ),
            argument: SQLiteLibrary.FunctionCallbacks.Argument(
              type: {
                SQLCipher.sqlite3_value_type($0)
              },
              int64: {
                SQLCipher.sqlite3_value_int64($0)
              },
              double: {
                SQLCipher.sqlite3_value_double($0)
              },
              text: {
                SQLCipher.sqlite3_value_text($0)
              },
              blob: {
                SQLCipher.sqlite3_value_blob($0)
              },
              byteCount: {
                SQLCipher.sqlite3_value_bytes($0)
              }
            ),
            result: SQLiteLibrary.FunctionCallbacks.Result(
              null: {
                SQLCipher.sqlite3_result_null($0)
              },
              int64: {
                SQLCipher.sqlite3_result_int64($0, $1)
              },
              double: {
                SQLCipher.sqlite3_result_double($0, $1)
              },
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
              error: {
                SQLCipher.sqlite3_result_error($0, $1, $2)
              }
            )
          )
        ),
        aggregateFunctions: SQLiteLibrary.AggregateFunctions(
          register: {
            SQLCipher.sqlite3_create_function_v2($0, $1, $2, $3, $4, $5, $6, $7, $8)
          },
          context: {
            SQLCipher.sqlite3_aggregate_context($0, $1)
          },
          callbacks: SQLiteLibrary.FunctionCallbacks(
            context: SQLiteLibrary.FunctionCallbacks.Context(
              userData: {
                SQLCipher.sqlite3_user_data($0)
              }
            ),
            argument: SQLiteLibrary.FunctionCallbacks.Argument(
              type: {
                SQLCipher.sqlite3_value_type($0)
              },
              int64: {
                SQLCipher.sqlite3_value_int64($0)
              },
              double: {
                SQLCipher.sqlite3_value_double($0)
              },
              text: {
                SQLCipher.sqlite3_value_text($0)
              },
              blob: {
                SQLCipher.sqlite3_value_blob($0)
              },
              byteCount: {
                SQLCipher.sqlite3_value_bytes($0)
              }
            ),
            result: SQLiteLibrary.FunctionCallbacks.Result(
              null: {
                SQLCipher.sqlite3_result_null($0)
              },
              int64: {
                SQLCipher.sqlite3_result_int64($0, $1)
              },
              double: {
                SQLCipher.sqlite3_result_double($0, $1)
              },
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
              error: {
                SQLCipher.sqlite3_result_error($0, $1, $2)
              }
            )
          )
        ),
        collations: SQLiteLibrary.Collations(
          create: {
            SQLCipher.sqlite3_create_collation_v2($0, $1, $2, $3, $4, $5)
          }
        ),
        encryption: SQLiteLibrary.Encryption(
          key: {
            SQLCipher.sqlite3_key_v2($0, $1, $2, $3)
          },
          rekey: {
            SQLCipher.sqlite3_rekey_v2($0, $1, $2, $3)
          }
        ),
        extensions: \#(extensions)
      )
      """#
    }
  }

  @Test(arguments: ["[]", "[/* no optional APIs */]"])
  func qualifiedLibraryWithOnlyRequiredAPIs(apis: String) {
    assertMacro {
      """
      let library = #sqliteLibrary(module: "TursoSQLite3", apis: \(apis))
      """
    } expansion: {
      """
      let library = SQLiteLibrary(
        runtime: SQLiteLibrary.Runtime(
          threadsafe: {
            TursoSQLite3.sqlite3_threadsafe()
          },
          versionNumber: {
            TursoSQLite3.sqlite3_libversion_number()
          }
        ),
        connections: SQLiteLibrary.Connections(
          open: {
            TursoSQLite3.sqlite3_open_v2($0, $1, $2, $3)
          },
          close: {
            TursoSQLite3.sqlite3_close_v2($0)
          },
          errorMessage: {
            TursoSQLite3.sqlite3_errmsg($0)
          },
          extendedErrorCode: {
            TursoSQLite3.sqlite3_extended_errcode($0)
          },
          setExtendedResultCodes: {
            TursoSQLite3.sqlite3_extended_result_codes($0, $1)
          },
          setBusyTimeout: {
            TursoSQLite3.sqlite3_busy_timeout($0, $1)
          },
          interrupt: {
            TursoSQLite3.sqlite3_interrupt($0)
          },
          changes: {
            TursoSQLite3.sqlite3_changes64($0)
          },
          lastInsertedRowID: {
            TursoSQLite3.sqlite3_last_insert_rowid($0)
          },
          isAutocommit: {
            TursoSQLite3.sqlite3_get_autocommit($0)
          },
          walCheckpoint: {
            TursoSQLite3.sqlite3_wal_checkpoint_v2($0, $1, $2, $3, $4)
          }
        ),
        statements: SQLiteLibrary.Statements(
          preparation: SQLiteLibrary.StatementPreparation(
            prepare: {
              TursoSQLite3.sqlite3_prepare_v3($0, $1, $2, $3, $4, $5)
            }
          ),
          execution: SQLiteLibrary.StatementExecution(
            step: {
              TursoSQLite3.sqlite3_step($0)
            },
            reset: {
              TursoSQLite3.sqlite3_reset($0)
            },
            finalize: {
              TursoSQLite3.sqlite3_finalize($0)
            },
            clearBindings: {
              TursoSQLite3.sqlite3_clear_bindings($0)
            }
          ),
          inspection: SQLiteLibrary.StatementInspection(
            isReadOnly: {
              TursoSQLite3.sqlite3_stmt_readonly($0)
            },
            sql: {
              TursoSQLite3.sqlite3_sql($0)
            }
          )
        ),
        bindings: SQLiteLibrary.Bindings(
          parameterCount: {
            TursoSQLite3.sqlite3_bind_parameter_count($0)
          },
          null: {
            TursoSQLite3.sqlite3_bind_null($0, $1)
          },
          int64: {
            TursoSQLite3.sqlite3_bind_int64($0, $1, $2)
          },
          double: {
            TursoSQLite3.sqlite3_bind_double($0, $1, $2)
          },
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
        columns: SQLiteLibrary.Columns(
          count: {
            TursoSQLite3.sqlite3_column_count($0)
          },
          type: {
            TursoSQLite3.sqlite3_column_type($0, $1)
          },
          int64: {
            TursoSQLite3.sqlite3_column_int64($0, $1)
          },
          double: {
            TursoSQLite3.sqlite3_column_double($0, $1)
          },
          text: {
            TursoSQLite3.sqlite3_column_text($0, $1)
          },
          blob: {
            TursoSQLite3.sqlite3_column_blob($0, $1)
          },
          byteCount: {
            TursoSQLite3.sqlite3_column_bytes($0, $1)
          },
          name: {
            TursoSQLite3.sqlite3_column_name($0, $1)
          }
        ),
        authorizer: nil,
        busyHandler: nil,
        trustedSchema: nil,
        scalarFunctions: nil,
        aggregateFunctions: nil,
        collations: nil,
        encryption: nil,
        extensions: nil
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

  @Test
  func apiArrayCannotReferenceVariables() {
    assertMacro {
      """
      let authorizer: SQLiteLibrary.APIs = .encryption
      let library = #sqliteLibrary(apis: [authorizer])
      """
    } diagnostics: {
      """
      let authorizer: SQLiteLibrary.APIs = .encryption
      let library = #sqliteLibrary(apis: [authorizer])
                                         ┬───────────
                                         ╰─ 🛑 'apis' must be '.standard', '.all', '[]', or an array literal of API members
      """
    }
  }
}
