#if BuiltInSQLite
  import StructuredQueriesSQLite
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct SQLiteErrorTests {
    @Test(
      arguments: [
        // `SQLITE_BUSY`, then its `_RECOVERY`, `_SNAPSHOT`, and `_TIMEOUT` extended codes.
        5, 261, 517, 773,
        // `SQLITE_LOCKED`, then its `_SHAREDCACHE` and `_VTAB` extended codes.
        6, 262, 518
      ] as [Int32]
    )
    func everyBusyOrLockedCodeIsBusy(_ code: Int32) {
      let error = SQLiteError(code: SQLiteResultCode(rawValue: code))
      #expect(error.isBusy)
      #expect(!error.isInterruption)
    }

    @Test(
      arguments: [
        // `SQLITE_ERROR`, `SQLITE_CONSTRAINT`, and `SQLITE_INTERRUPT`.
        1, 19, 9,
        // `SQLITE_IOERR_LOCK`, which is about a lock yet is an I/O failure rather than contention.
        3850,
        // `SQLITE_CONSTRAINT_UNIQUE`, whose extended bits must not be mistaken for a busy code.
        2067
      ] as [Int32]
    )
    func otherCodesAreNotBusy(_ code: Int32) {
      #expect(!SQLiteError(code: SQLiteResultCode(rawValue: code)).isBusy)
    }

    @Test
    func onlyAnInterruptIsAnInterruption() {
      #expect(SQLiteError(code: .interrupt).isInterruption)
      #expect(!SQLiteError(code: .busy).isInterruption)
      #expect(!SQLiteError(code: .error).isInterruption)
    }

    @Test
    func aStatementInterruptedWhileSteppingReportsAnInterruption() throws {
      // The connection's address, published once it is open, so a step can interrupt it. A step
      // that is already under way is the only kind SQLite does not clear an interrupt for.
      let address = Lock<UInt?>(nil)
      let steps = Lock(0)
      let base = builtInTestLibrary
      var configuration = SQLiteConfiguration.default
      configuration.library.statements.execution.step = { statement in
        if let sql = base.statements.inspection.sql(statement),
          String(cString: sql).contains("RECURSIVE counter"),
          steps.withLock({
            $0 += 1
            return $0
          }) == 2,
          let address = address.withLock({ $0 })
        {
          base.connections.interrupt(OpaquePointer(bitPattern: address))
        }
        return base.statements.execution.step(statement)
      }
      let handle = try SQLiteHandle.open(
        path: .memory,
        flags: [.readWrite, .create, .memory, .noMutex],
        configuration: configuration
      )
      address.withLock { $0 = UInt(bitPattern: Int(bitPattern: handle.pointer)) }

      let error = #expect(throws: SQLiteError.self) {
        try handle.read { transaction in
          try transaction.fetchAll(
            #sql(
              """
              WITH RECURSIVE counter(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 1000
              )
              SELECT x FROM counter
              """,
              as: Int.self
            )
          )
        }
      }

      #expect(error?.isInterruption == true)
      #expect(error?.isBusy == false)
    }
  }
#endif
