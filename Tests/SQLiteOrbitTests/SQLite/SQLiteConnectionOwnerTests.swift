#if BuiltInSQLite
  import Foundation
  import SQLiteOrbit
  import Testing

  @Suite
  struct SQLiteConnectionOwnerTests {
    @Test
    func synchronousAccessKeepsCallerStateAndReturnsNonSendableAndNoncopyableValues() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let callerState = OwnerCallerState()

      let result = try owner.withWriteConnection { connection in
        try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try connection.transaction { transaction in
          try transaction.execute("INSERT INTO items VALUES (42)")
        }
        callerState.value = 42
        return callerState
      }
      #expect(result === callerState)
      #expect(callerState.value == 42)

      let unique = try owner.withReadConnection { connection in
        try connection.transaction { transaction in
          OwnerUniqueResult(
            value: try transaction.fetchOne("SELECT id FROM items") { $0[0].integerValue ?? 0 } ?? 0
          )
        }
      }
      #expect(unique.value == 42)
      let isReadOnly = owner.isReadOnly
      let configuration = owner.configuration
      #expect(!isReadOnly)
      #expect(configuration.isForeignKeysEnabled)
    }

    @Test(arguments: [SQLiteWriteTransactionMode.deferred, .immediate, .exclusive])
    func transactionsCommitOrRollBackAndLeaveTheOwnerUsable(mode: SQLiteWriteTransactionMode)
      throws
    {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      try owner.withWriteConnection { connection in
        try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try connection.transaction(mode: mode) { transaction in
          try transaction.execute("INSERT INTO items VALUES (1)")
        }
        #expect(throws: OwnerTestFailure.self) {
          try connection.transaction(mode: mode) { transaction in
            try transaction.execute("INSERT INTO items VALUES (2)")
            throw OwnerTestFailure()
          }
        }
        try connection.transaction { transaction in
          try transaction.execute("INSERT INTO items VALUES (3)")
        }
      }
      let ids = try owner.withReadConnection { connection in
        try connection.fetchAll("SELECT id FROM items ORDER BY id") { $0[0].integerValue ?? 0 }
      }
      #expect(ids == [1, 3])
    }

    @Test
    func readAccessRefusesMutationAndAReadOnlyOwnerRefusesWriteAccess() throws {
      try withTemporaryDirectory("owner") { directory in
        let path = OrbitDatabasePath(directory.appendingPathComponent("database.sqlite").path)
        do {
          var writer = try SQLiteConnection(path: path, configuration: .default)
          try writer.withWriteConnection { connection in
            try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
            try connection.execute("INSERT INTO items VALUES (1)")
          }
          let error = #expect(throws: SQLiteError.self) {
            try writer.withReadConnection { connection in
              var cursor = try connection.rowCursor("INSERT INTO items VALUES (2)")
              while try cursor.next() != nil {}
            }
          }
          #expect(error?.primaryCode == .readOnly)
          try writer.withWriteConnection { connection in
            try connection.execute("INSERT INTO items VALUES (3)")
          }
        }

        var reader = try SQLiteConnection(path: path, configuration: .default, flags: [.readOnly])
        let isReadOnly = reader.isReadOnly
        #expect(isReadOnly)
        let error = #expect(throws: SQLiteError.self) {
          try reader.withWriteConnection { _ in
            Issue.record("A read-only owner lent a writable connection")
          }
        }
        #expect(error?.primaryCode == .readOnly)
        let ids = try reader.withReadConnection { connection in
          try connection.fetchAll("SELECT id FROM items ORDER BY id") { $0[0].integerValue ?? 0 }
        }
        #expect(ids == [1, 3])
      }
    }

    @Test
    func scopedObserversSeeTransactionOrderingRollbackAndStatementCommits() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let observer = TransactionEventRecorder(countOnWillCommit: "SELECT count(*) FROM items")
      let items = OrbitDatabaseRegion(table: "items")
      try owner.withWriteConnection { connection in
        try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try connection.withObservation(observer) {
          try connection.transaction { transaction in
            try transaction.execute("INSERT INTO items VALUES (1)")
          }
          #expect(observer.events == [.didChange(items), .willCommit(1), .didCommit(.local)])
          #expect(observer.commits.map(\.region) == [items])
          #expect(observer.readRegions.contains { !$0.isDisjoint(with: items) })

          observer.removeAll()
          #expect(throws: OwnerTestFailure.self) {
            try connection.transaction { transaction in
              try transaction.execute("INSERT INTO items VALUES (2)")
              throw OwnerTestFailure()
            }
          }
          #expect(observer.events == [.didChange(items), .didRollback])

          observer.removeAll()
          try connection.execute("INSERT INTO items VALUES (3)")
          #expect(observer.events == [.didChange(items), .didCommit(.local)])
          #expect(observer.commits.map(\.region) == [items])
        }
        observer.removeAll()
        try connection.execute("INSERT INTO items VALUES (4)")
        #expect(observer.events.isEmpty)
      }
      let ids = try owner.withReadConnection { connection in
        try connection.withObservation(observer) {
          try connection.fetchAll("SELECT id FROM items ORDER BY id") { $0[0].integerValue ?? 0 }
        }
      }
      #expect(ids == [1, 3, 4])
      #expect(observer.readRegions.contains { !$0.isDisjoint(with: items) })
    }

    @Test(arguments: [false, true])
    func aRejectingObserverReceivesRollbackAndStopsAfterItsScope(transactionScoped: Bool) throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let observer = TransactionEventRecorder(
        countOnWillCommit: "SELECT count(*) FROM items",
        commitError: OwnerTestFailure()
      )
      let items = OrbitDatabaseRegion(table: "items")
      try owner.withWriteConnection { connection in
        try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        #expect(throws: OwnerTestFailure.self) {
          if transactionScoped {
            try connection.transaction(observer: observer) { transaction in
              try transaction.execute("INSERT INTO items VALUES (1)")
            }
          } else {
            try connection.withObservation(observer) {
              try connection.transaction { transaction in
                try transaction.execute("INSERT INTO items VALUES (1)")
              }
            }
          }
        }
        #expect(observer.events == [.didChange(items), .willCommit(1), .didRollback])
        #expect(observer.commits.isEmpty)
        observer.removeAll()
        try connection.transaction { transaction in
          try transaction.execute("INSERT INTO items VALUES (2)")
        }
        #expect(observer.events.isEmpty)
      }
      let ids = try owner.withReadConnection { connection in
        try connection.fetchAll("SELECT id FROM items") { $0[0].integerValue ?? 0 }
      }
      #expect(ids == [2])
    }

    @Test
    func transactionObserverSpansItsLifecycleInsideAnOuterConnectionScope() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let outer = TransactionEventRecorder(countOnWillCommit: "SELECT count(*) FROM items")
      let transactionObserver = TransactionEventRecorder(
        countOnWillCommit: "SELECT count(*) FROM items"
      )
      let items = OrbitDatabaseRegion(table: "items")

      try owner.withWriteConnection { connection in
        try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try connection.withObservation(outer) {
          try connection.transaction(observer: transactionObserver) { transaction in
            try transaction.execute("INSERT INTO items VALUES (1)")
          }
          let expected: [TransactionEventRecorder.Event] = [
            .didChange(items), .willCommit(1), .didCommit(.local)
          ]
          #expect(outer.events == expected)
          #expect(transactionObserver.events == expected)
          #expect(transactionObserver.commits.map(\.region) == [items])
          #expect(outer.commits.map(\.region) == [items])

          transactionObserver.removeAll()
          try connection.execute("INSERT INTO items VALUES (2)")
          #expect(transactionObserver.events.isEmpty)
          #expect(outer.events == expected + [.didChange(items), .didCommit(.local)])
          #expect(outer.commits.map(\.region) == [items, items])

          #expect(throws: OwnerTestFailure.self) {
            try connection.transaction(observer: transactionObserver) { transaction in
              try transaction.execute("INSERT INTO items VALUES (3)")
              throw OwnerTestFailure()
            }
          }
          #expect(transactionObserver.events == [.didChange(items), .didRollback])
          #expect(transactionObserver.commits.isEmpty)
        }
      }
    }

    @Test
    func readTransactionObserverStopsBeforeTheNextConnectionStatement() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let observer = TransactionEventRecorder(countOnWillCommit: "SELECT count(*) FROM items")
      let items = OrbitDatabaseRegion(table: "items")
      try owner.withWriteConnection { connection in
        try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
        try connection.execute("INSERT INTO items VALUES (1)")
      }
      try owner.withReadConnection { connection in
        let result = try connection.transaction(observer: observer) { transaction in
          try transaction.fetchOne("SELECT id FROM items") { $0[0].integerValue ?? 0 }
        }
        #expect(result == 1)
        let reads = observer.readRegions
        #expect(reads.contains { $0.overlaps(items) })
        _ = try connection.fetchOne("SELECT id FROM items") { $0[0].integerValue ?? 0 }
        #expect(observer.readRegions == reads)
        #expect(observer.events.isEmpty)
      }
    }

    @Test
    func nestedStatementExecutionScopesRestoreThePreviousWrapperAfterThrowing() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let calls = TestRecorder<String>()
      try owner.withWriteConnection { connection in
        let original = connection.sqlite.statements.execution.step
        #expect(throws: OwnerTestFailure.self) {
          try connection.withStatementExecution(
            { statement in
              calls.append("outer")
              return original(statement)
            }
          ) {
            _ = try connection.fetchOne("SELECT 1") { $0[0].integerValue ?? 0 }
            #expect(!calls.values.isEmpty)
            #expect(calls.values.allSatisfy { $0 == "outer" })

            calls.removeAll()
            let outer = connection.sqlite.statements.execution.step
            do {
              try connection.withStatementExecution(
                { statement in
                  calls.append("inner")
                  return outer(statement)
                }
              ) {
                _ = try connection.fetchOne("SELECT 2") { $0[0].integerValue ?? 0 }
                throw OwnerTestFailure()
              }
              Issue.record("The inner statement execution scope did not throw")
            } catch {
              #expect(error is OwnerTestFailure)
            }
            #expect(calls.values.contains("inner"))
            #expect(calls.values.contains("outer"))

            calls.removeAll()
            _ = try connection.fetchOne("SELECT 3") { $0[0].integerValue ?? 0 }
            #expect(!calls.values.isEmpty)
            #expect(calls.values.allSatisfy { $0 == "outer" })
            throw OwnerTestFailure()
          }
        }
        calls.removeAll()
        _ = try connection.fetchOne("SELECT 4") { $0[0].integerValue ?? 0 }
        #expect(calls.values.isEmpty)
      }
      _ = try owner.withReadConnection { connection in
        try connection.fetchOne("SELECT 5") { $0[0].integerValue ?? 0 }
      }
      #expect(calls.values.isEmpty)
    }

    @Test
    func cancellingBeforeAccessSkipsItsBodyAndLateCancellationLeavesLaterAccessesAlone() throws {
      var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
      let cancelled = SQLiteConnectionCancellation()
      cancelled.cancel()
      cancelled.cancel()
      var didRun = false
      #expect(throws: CancellationError.self) {
        try owner.withReadConnection(cancellation: cancelled) { _ in didRun = true }
      }
      #expect(!didRun)

      let completed = SQLiteConnectionCancellation()
      let first = try owner.withReadConnection(cancellation: completed) { connection in
        try connection.fetchOne("SELECT 1") { $0[0].integerValue ?? 0 }
      }
      #expect(first == 1)
      completed.cancel()
      completed.cancel()
      let next = try owner.withReadConnection { connection in
        try connection.fetchOne("SELECT 2") { $0[0].integerValue ?? 0 }
      }
      #expect(next == 2)
    }

    @Test
    func releasingTheOwnerFinalizesCachedStatementsBeforeClosingItsConfiguredLibrary() throws {
      let counters = OwnerLibraryCounters()
      var configuration = SQLiteConfiguration.default
      configuration.library = ownerCountingLibrary(counters)
      do {
        var owner = try SQLiteConnection(path: ":memory:", configuration: configuration)
        try owner.withReadConnection { connection in
          let statements: [SQL] = ["SELECT 1", "SELECT 2"]
          for sql in statements {
            var cursor = try connection.rowCursor(sql, cached: true)
            while try cursor.next() != nil {}
          }
        }
        #expect(counters.snapshot.closed == 0)
        #expect(counters.snapshot.prepared > counters.snapshot.finalized)
      }
      let counts = counters.snapshot
      #expect(counts.opened == 1)
      #expect(counts.closed == 1)
      #expect(counts.prepared == counts.finalized)
      #expect(counts.allStatementsFinalizedBeforeClose)
      #expect(counts.closeCodes == [SQLiteResultCode.ok.rawValue])
    }

    @Test(arguments: [false, true])
    func failedSetupClosesAnOpenedHandleButPreparationFailureDoesNotOpenOne(
      failsBeforeOpening: Bool
    ) {
      let counters = OwnerLibraryCounters()
      var configuration = SQLiteConfiguration.default
      configuration.library = ownerCountingLibrary(counters)
      configuration.connectionSetups = [
        SQLiteConnectionSetup(
          prepare: { _ in
            if failsBeforeOpening { throw OwnerTestFailure() }
          },
          install: { _ in throw OwnerTestFailure() }
        )
      ]
      #expect(throws: OwnerTestFailure.self) {
        _ = try SQLiteConnection(path: ":memory:", configuration: configuration)
      }
      let counts = counters.snapshot
      #expect(counts.opened == (failsBeforeOpening ? 0 : 1))
      #expect(counts.closed == counts.opened)
      #expect(counts.prepared == counts.finalized)
      #expect(counts.allStatementsFinalizedBeforeClose)
    }

    #if !Turso
      @Test
      func configuredFunctionsUseTheOwnersLibraryForTheirCallbacks() throws {
        var configuration = SQLiteConfiguration.default
        let base = try #require(configuration.library.scalarFunctions)
        configuration.library.scalarFunctions?.callbacks.argument.int64 = { value in
          base.callbacks.argument.int64(value) + 100
        }
        configuration.registerFunction("owner_identity", argumentCount: 1) { arguments in
          .integer(arguments[0].integerValue ?? 0)
        }
        var owner = try SQLiteConnection(path: ":memory:", configuration: configuration)
        let result = try owner.withReadConnection { connection in
          try connection.fetchOne("SELECT owner_identity(4)") { $0[0].integerValue ?? 0 }
        }
        #expect(result == 104)
      }

      @Test
      func cancellationInterruptsActiveSQLAndLeavesTheOwnerUsable() throws {
        let cancellation = SQLiteConnectionCancellation()
        var configuration = SQLiteConfiguration.default
        configuration.registerFunction("cancel_owner", argumentCount: 0) { _ in
          cancellation.cancel()
          return .integer(0)
        }
        var owner = try SQLiteConnection(path: ":memory:", configuration: configuration)
        #expect(throws: CancellationError.self) {
          try owner.withReadConnection(cancellation: cancellation) { connection in
            _ = try connection.fetchAll(
              """
              WITH RECURSIVE counter(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 1000
              )
              SELECT sum(cancel_owner() + x) FROM counter
              """
            ) { $0[0].integerValue ?? 0 }
          }
        }
        let result = try owner.withReadConnection { connection in
          try connection.fetchOne("SELECT 7") { $0[0].integerValue ?? 0 }
        }
        #expect(result == 7)
      }
    #endif
  }

  private final class OwnerCallerState {
    var value = 0
  }

  private struct OwnerUniqueResult: ~Copyable {
    let value: Int64
  }

  private struct OwnerTestFailure: Error {}

  private final class OwnerLibraryCounters: @unchecked Sendable {
    struct Snapshot {
      var opened = 0
      var closed = 0
      var prepared = 0
      var finalized = 0
      var allStatementsFinalizedBeforeClose = true
      var closeCodes: [Int32] = []
    }

    private let lock = NSLock()
    private var counts = Snapshot()

    var snapshot: Snapshot { lock.withLock { counts } }

    func record(_ update: (inout Snapshot) -> Void) {
      lock.withLock { update(&counts) }
    }
  }

  private func ownerCountingLibrary(_ counters: OwnerLibraryCounters) -> SQLiteLibrary {
    let base = SQLiteConfiguration.default.library
    var library = base
    library.connections.open = { path, pointer, flags, vfs in
      let code = base.connections.open(path, pointer, flags, vfs)
      if pointer?.pointee != nil { counters.record { $0.opened += 1 } }
      return code
    }
    library.connections.close = { pointer in
      let code = base.connections.close(pointer)
      counters.record {
        $0.closed += 1
        $0.allStatementsFinalizedBeforeClose =
          $0.allStatementsFinalizedBeforeClose && $0.prepared == $0.finalized
        $0.closeCodes.append(code)
      }
      return code
    }
    library.statements.preparation.prepare = { connection, sql, count, flags, statement, tail in
      let code = base.statements.preparation.prepare(connection, sql, count, flags, statement, tail)
      if code == SQLiteResultCode.ok.rawValue, statement?.pointee != nil {
        counters.record { $0.prepared += 1 }
      }
      return code
    }
    library.statements.execution.finalize = { statement in
      if statement != nil { counters.record { $0.finalized += 1 } }
      return base.statements.execution.finalize(statement)
    }
    return library
  }
#endif
