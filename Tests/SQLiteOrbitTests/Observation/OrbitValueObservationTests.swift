#if StructuredQueries
  import StructuredQueriesSQLite

  #if BuiltInSQLite
    import Foundation
    import StructuredQueriesSQLite
    import Testing

    @testable import SQLiteOrbit

    @Suite
    struct OrbitValueObservationTests {
      @Test
      func callbackSubscriptionEmitsInitialAndLocalChanges() async throws {
        let driver = try await itemsDatabase()
        let observation = itemCountObservation()
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

        try await recorder.waitForChangeCount(1)
        try await insertItems(1, into: driver)
        try await recorder.waitForChangeCount(2)

        #expect(recorder.changes.map(\.value) == [0, 1])
        #expect(recorder.changes.map(\.source) == [.initial, .transaction(.local)])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }

      @Test
      func immediateSchedulerDeliversTheInitialValueAndCommitsBeforeTheCallsReturn() throws {
        let driver = try blockingItemsDatabase()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation()
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        #expect(recorder.changes.map(\.value) == [0])
        #expect(recorder.changes.map(\.source) == [.initial])

        try insertItemsBlocking(1, into: driver)

        #expect(recorder.changes.map(\.value) == [0, 1])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }

      @MainActor
      @Test
      func cancelledSubscriberDoesNotReceiveAChangeAlreadyOnItsWay() async throws {
        let driver = try blockingItemsDatabase()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation()
          .subscribe(
            to: driver,
            scheduling: .mainActor,
            onError: { error in recorder.record(error: error) },
            onChange: { change in recorder.record(change: change) }
          )
        #expect(recorder.changes.map(\.value) == [0])

        // The commit publishes from this thread, and its delivery is queued for the main actor,
        // which nothing here gives up before the subscription is cancelled.
        try insertItemsBlocking(1, into: driver)
        subscription.cancel()

        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.changes.map(\.value) == [0])
        #expect(recorder.errors.isEmpty)
      }

      @MainActor
      @Test
      func mainActorSchedulerIsImmediateWhenStartedOnMainActor() async throws {
        let driver = try await itemsDatabase()
        let recorder = MainActorObservationRecorder<Int>()

        let subscription = try itemCountObservation()
          .subscribe(
            to: driver,
            scheduling: .mainActor,
            onError: { @MainActor error in
              recorder.errors.append(String(describing: error))
            },
            onChange: { @MainActor change in
              recorder.changes.append(change)
            }
          )

        #expect(recorder.changes.map(\.value) == [0])

        try await insertItems(1, into: driver)
        try await recorder.waitForChangeCount(2)

        #expect(recorder.changes.map(\.value) == [0, 1])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }

      @Test
      func mainActorSchedulerDefersWhenStartedOutsideMainActor() async throws {
        let driver = try await itemsDatabase()
        let recorder = ObservationRecorder<Int>()

        let subscription = try itemCountObservation()
          .subscribe(
            to: driver,
            scheduling: .mainActor,
            isolation: nil,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        #expect(recorder.changes.isEmpty)
        try await recorder.waitForChangeCount(1)
        #expect(recorder.changes.map(\.value) == [0])
        _ = subscription
      }

      @Test
      func rolledBackWriteDoesNotEmitItsStagedValue() async throws {
        let driver = try await itemsDatabase()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation()
          .subscribe(
            to: driver,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
        try await recorder.waitForChangeCount(1)

        await #expect(throws: TestError.self) {
          try await driver.write { transaction in
            try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
            throw TestError()
          }
        }
        try await insertItems(2, into: driver)
        try await recorder.waitForChangeCount(2)

        #expect(recorder.changes.map(\.value) == [0, 1])
        _ = subscription
      }

      @Test
      func constantRegionObservesWhatItsFirstFetchReadAndIgnoresATableOnlyALaterFetchReads()
        async throws
      {
        let driver = try await itemsDatabase()
        try await driver.execute(sql: "CREATE TABLE labels (id INTEGER PRIMARY KEY)")
        // The second table is read only once the first has a row, so the first fetch never reaches
        // it and the recorded region never mentions it.
        let observation = OrbitValueObservation<Int>
          .trackingConstantRegion { transaction in
            let labelCount = #sql("SELECT COUNT(*) FROM labels", as: Int.self)
            let items = try transaction.fetchOne(itemCountQuery) ?? 0
            guard items > 0 else { return 0 }
            return try items + (transaction.fetchOne(labelCount) ?? 0)
          }
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)
        try await insertItems(1, into: driver)
        try await recorder.waitForChangeCount(2)

        try await driver.write { transaction in
          try transaction.execute(#sql("INSERT INTO labels (id) VALUES (1)", as: Void.self))
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(recorder.changes.map(\.value) == [0, 1])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }

      @Test
      func taskScopedSubscribeDeliversChanges() async throws {
        let driver = try await itemsDatabase()
        let recorder = ObservationRecorder<Int>()
        let observing = Task {
          try await itemCountObservation()
            .subscribe(to: driver, scheduling: .async(), onChange: recorder.record(change:))
        }
        defer { observing.cancel() }
        try await recorder.waitForChangeCount(1)

        try await insertItems(1, into: driver)
        try await recorder.waitForChangeCount(2)

        #expect(recorder.changes.map(\.value) == [0, 1])
        #expect(recorder.changes.map(\.source) == [.initial, .transaction(.local)])
      }

      @Test
      func taskScopedSubscribeReturnsAndStopsObservingWhenItsTaskIsCancelled() async throws {
        let driver = try await itemsDatabase()
        let events = TestRecorder<String>()
        let recorder = ObservationRecorder<Int>()
        let observation = itemCountObservation()
          .handleEvents(didCancel: { events.append("didCancel") })
        let observing = Task {
          try await observation
            .subscribe(to: driver, scheduling: .async(), onChange: recorder.record(change:))
        }
        try await recorder.waitForChangeCount(1)

        observing.cancel()
        // Cancellation is how it ends, so it returns rather than throwing.
        try await observing.value
        #expect(events.values == ["didCancel"])

        try await insertItems(1, into: driver)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.changes.map(\.value) == [0])
      }

      @Test
      func taskScopedSubscribeReturnsAtOnceInAnAlreadyCancelledTask() async throws {
        let driver = try await itemsDatabase()
        let observing = Task {
          withUnsafeCurrentTask { $0?.cancel() }
          try await itemCountObservation().subscribe(to: driver, scheduling: .async()) { _ in }
        }

        try await observing.value
      }

      @Test
      func taskScopedSubscribeThrowsTheErrorThatEndsTheObservation() async throws {
        let driver = try await itemsDatabase()
        let observation = OrbitValueObservation<Int>.tracking { _ in throw TestError() }

        await #expect(throws: TestError.self) {
          try await observation.subscribe(to: driver, scheduling: .async()) { _ in }
        }
      }

      @Test
      func commitFailureDiscardsThePendingValue() async throws {
        let driver = try SQLiteQueue(path: .memory)
        try await driver.execute(
          sql: """
            CREATE TABLE parents (id INTEGER PRIMARY KEY);
            CREATE TABLE children (
              parent_id INTEGER NOT NULL REFERENCES parents(id)
                DEFERRABLE INITIALLY DEFERRED
            );
            """
        )
        let observation = OrbitValueObservation<Int>
          .tracking { transaction in
            try transaction.fetchOne(#sql("SELECT COUNT(*) FROM children", as: Int.self)) ?? 0
          }
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)

        await #expect(throws: (any Error).self) {
          try await driver.write { transaction in
            try transaction.execute(
              #sql("INSERT INTO children (parent_id) VALUES (1)", as: Void.self)
            )
          }
        }
        try await driver.write { transaction in
          try transaction.execute(#sql("INSERT INTO parents (id) VALUES (1)", as: Void.self))
          try transaction.execute(
            #sql("INSERT INTO children (parent_id) VALUES (1)", as: Void.self)
          )
        }
        try await recorder.waitForChangeCount(2)

        #expect(recorder.changes.map(\.value) == [0, 1])
        _ = subscription
      }

      @Test
      func changesSequencePreservesSourceMetadata() async throws {
        let driver = try await itemsDatabase()
        let changes = itemCountObservation().changes(in: driver)
        var iterator = changes.makeAsyncIterator()

        let initial = try #require(try await iterator.next())
        #expect(initial.value == 0)
        #expect(initial.source == .initial)

        try await insertItems(1, into: driver)
        let local = try #require(try await iterator.next())
        #expect(local.value == 1)
        #expect(local.source == .transaction(.local))
      }

      @Test
      func updatesSequenceIncludesFetchesThatEmitNoValue() async throws {
        let driver = try await itemsDatabase()
        let updates = itemCountObservation()
          .filter { $0.isMultiple(of: 2) == false }
          .updates(in: driver)
          .prefix(3)
        var iterator = updates.makeAsyncIterator()

        #expect(try await iterator.next() == .noEmission(source: .initial))

        try await insertItems(1, into: driver)
        #expect(
          try await iterator.next()
            == .emitted(
              OrbitValueObservationChange(value: 1, source: .transaction(.local))
            )
        )

        try await insertItems(2, into: driver)
        #expect(try await iterator.next() == .noEmission(source: .transaction(.local)))
      }

      @Test
      func updatesSequenceCatchesUpWithoutRefetchingOrErasingTheLatestValue() async throws {
        let driver = try await itemsDatabase()
        let fetchCount = TestCounter()
        let observation = itemCountObservation(countingFetchesIn: fetchCount)
          .filter { $0 > 0 }

        var first = observation.updates(in: driver).makeAsyncIterator()
        #expect(try await first.next() == .noEmission(source: .initial))

        var second = observation.updates(in: driver).makeAsyncIterator()
        #expect(try await second.next() == .noEmission(source: .initial))
        #expect(fetchCount.value == 1)

        try await insertItems(1, into: driver)
        #expect(
          try await first.next()
            == .emitted(
              OrbitValueObservationChange(value: 1, source: .transaction(.local))
            )
        )

        try await driver.write { transaction in
          try transaction.execute(#sql("DELETE FROM items", as: Void.self))
        }
        #expect(try await first.next() == .noEmission(source: .transaction(.local)))

        var third = observation.updates(in: driver).makeAsyncIterator()
        #expect(
          try await third.next()
            == .emitted(
              OrbitValueObservationChange(value: 1, source: .transaction(.local))
            )
        )
        #expect(fetchCount.value == 3)
        _ = second
      }

      @Test
      func interprocessObservationIgnoresDisjointRegions() async throws {
        let (database, peer, identifier) = try await announcingItemsDatabase("external-regions")
        let fetchCount = TestCounter()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation(
          region: itemsRegion,
          countingFetchesIn: fetchCount
        )
        .subscribe(
          to: database,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)

        for region in [OrbitDatabaseRegion.empty, OrbitDatabaseRegion(table: "unrelated")] {
          try await peer.send(
            commit(identifier, region: region)
          )
          #expect(fetchCount.value == 1)
        }

        try await peer.send(
          commit(identifier, region: itemsRegion)
        )
        try await recorder.waitForChangeCount(2)

        #expect(fetchCount.value == 2)
        #expect(recorder.changes.map(\.value) == [0, 0])
        #expect(recorder.changes.map(\.source) == [.initial, .transaction(.external)])
        _ = subscription
      }

      @Test
      func transactionFilterUsesTheCommitOriginBeforeFetching() async throws {
        let (database, peer, identifier) = try await announcingItemsDatabase("filtered-origin")
        let fetchCount = TestCounter()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation(countingFetchesIn: fetchCount)
          .filterTransactions { $0.origin == .external }
          .subscribe(
            to: database,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
        try await recorder.waitForChangeCount(1)

        try await insertItems(1, into: database)
        #expect(fetchCount.value == 1)

        try await peer.send(
          commit(identifier, region: .fullDatabase)
        )
        try await recorder.waitForChangeCount(2)

        #expect(fetchCount.value == 2)
        #expect(recorder.changes.map(\.value) == [0, 1])
        #expect(recorder.changes.map(\.source) == [.initial, .transaction(.external)])
        _ = subscription
      }

      @Test
      func transactionFilterReceivesThePreviousAcceptedValue() async throws {
        let driver = try await itemsDatabase()
        let previousValues = TestRecorder<Int?>()
        let fetchCount = TestCounter()
        let observation = itemCountObservation(countingFetchesIn: fetchCount)
          .removeDuplicates(by: { _, _ in true })
          .filterTransactions { _, previousValue in
            previousValues.append(previousValue)
            return true
          }
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)

        try await insertItems(1, into: driver)
        try await insertItems(2, into: driver)

        #expect(previousValues.values == [0, 0])
        #expect(fetchCount.value == 3)
        #expect(recorder.changes.map(\.value) == [0])
        _ = subscription
      }

      @Test
      func interprocessObservationSeesSiblingHandleWritesAsLocalAndSkipsDisjointOnes() async throws
      {
        try await withTestDatabaseFile("obs") { file in
          let identifier = OrbitDatabaseIdentifier(rawValue: "same-process-observation")
          let writingDatabase = OrbitIPCDatabase(
            writer: try file.queue(),
            id: identifier,
            transport: InMemoryIPCTransport()
          )
          try await writingDatabase.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
          let observingDatabase = OrbitIPCDatabase(
            writer: try file.queue(),
            id: identifier,
            transport: InMemoryIPCTransport()
          )
          let fetchCount = TestCounter()
          let recorder = ObservationRecorder<Int>()
          let subscription = try itemCountObservation(
            region: itemsRegion,
            countingFetchesIn: fetchCount
          )
          .subscribe(
            to: observingDatabase,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
          try await recorder.waitForChangeCount(1)

          try await writingDatabase.write { transaction in
            transaction.notifyChanges(in: OrbitDatabaseRegion(table: "unrelated"))
          }
          #expect(fetchCount.value == 1)

          try await insertItems(1, into: writingDatabase)
          try await recorder.waitForChangeCount(2)

          #expect(fetchCount.value == 2)
          #expect(recorder.changes.map(\.value) == [0, 1])
          #expect(recorder.changes.map(\.source) == [.initial, .transaction(.local)])
          _ = subscription
        }
      }

      @Test
      func writeOutsideATransactionRefetchesAsALocalCommit() async throws {
        let driver = try await itemsDatabase()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation()
          .subscribe(
            to: driver,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )
        try await recorder.waitForChangeCount(1)

        // Outside a transaction there is no `databaseWillCommit` to fetch in, so the observation
        // learns of the statement only once it has committed, and fetches again.
        try await driver.writeWithoutTransaction { connection in
          try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
        }
        try await recorder.waitForChangeCount(2)

        #expect(recorder.changes.map(\.value) == [0, 1])
        #expect(recorder.changes.map(\.source) == [.initial, .transaction(.local)])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }

      @Test
      func cancellingValueSubscriptionStopsRefetching() async throws {
        let driver = try await itemsDatabase()
        let fetchCount = TestCounter()
        let observation = itemCountObservation(countingFetchesIn: fetchCount)
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)
        subscription.cancel()

        try await insertItems(1, into: driver)

        #expect(fetchCount.value == 1)
      }

      @Test
      func subscribersShareOneRuntimeAndFetch() async throws {
        let driver = try await itemsDatabase()
        let fetchCount = TestCounter()
        let observation = itemCountObservation(countingFetchesIn: fetchCount)
        let first = ObservationRecorder<Int>()
        let second = ObservationRecorder<Int>()
        let subscriptions = try [
          observation.subscribe(
            to: driver,
            onError: first.record(error:),
            onChange: first.record(change:)
          ),
          observation.subscribe(
            to: driver,
            onError: second.record(error:),
            onChange: second.record(change:)
          )
        ]
        try await first.waitForChangeCount(1)
        try await second.waitForChangeCount(1)
        #expect(fetchCount.value == 1)

        try await insertItems(1, into: driver)
        try await first.waitForChangeCount(2)
        try await second.waitForChangeCount(2)

        #expect(first.changes.map(\.value) == [0, 1])
        #expect(second.changes.map(\.value) == [0, 1])
        #expect(fetchCount.value == 2)
        _ = subscriptions
      }

      @Test
      func removeDuplicatesSuppressesEqualCommittedValues() async throws {
        let driver = try await itemsDatabase()
        let changes = itemCountObservation().removeDuplicates().changes(in: driver)
        var iterator = changes.makeAsyncIterator()
        #expect(try await iterator.next()?.value == 0)

        try await driver.write { transaction in
          try transaction.execute(#sql("DELETE FROM items", as: Void.self))
        }
        try await insertItems(1, into: driver)

        #expect(try await iterator.next()?.value == 1)
      }

      @Test
      func mapTransformsValuesAndPreservesTheirSources() throws {
        let driver = try blockingItemsDatabase()
        let recorder = ObservationRecorder<String>()
        let subscription = try itemCountObservation()
          .map { "count=\($0)" }
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        try insertItemsBlocking(1, into: driver)

        #expect(recorder.changes.map(\.value) == ["count=0", "count=1"])
        #expect(recorder.changes.map(\.source) == [.initial, .transaction(.local)])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }

      @Test
      func filterSuppressesValuesWithoutRepeatingTheSharedInitialFetch() throws {
        let driver = try blockingItemsDatabase()
        let fetchCount = TestCounter()
        let observation = itemCountObservation(countingFetchesIn: fetchCount)
          .filter { $0 > 0 }
        let first = ObservationRecorder<Int>()
        let second = ObservationRecorder<Int>()
        let subscriptions = try [
          observation.subscribe(
            to: driver,
            scheduling: .immediate,
            onError: first.record(error:),
            onChange: first.record(change:)
          ),
          observation.subscribe(
            to: driver,
            scheduling: .immediate,
            onError: second.record(error:),
            onChange: second.record(change:)
          )
        ]

        #expect(first.changes.isEmpty)
        #expect(second.changes.isEmpty)
        #expect(fetchCount.value == 1)

        try insertItemsBlocking(1, into: driver)

        #expect(first.changes.map(\.value) == [1])
        #expect(second.changes.map(\.value) == [1])
        #expect(first.changes.map(\.source) == [.transaction(.local)])
        #expect(fetchCount.value == 2)
        _ = subscriptions
      }

      @Test
      func updateCallbackReceivesEmissionsAndNoEmissions() throws {
        let driver = try blockingItemsDatabase()
        let updates = TestRecorder<OrbitValueObservationUpdate<Int>>()
        let errors = TestRecorder<String>()
        let subscription = try itemCountObservation()
          .filter { $0.isMultiple(of: 2) == false }
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: { error in errors.append(String(describing: error)) },
            onUpdate: { update in updates.append(update) }
          )

        #expect(updates.values == [.noEmission(source: .initial)])

        try insertItemsBlocking(1, into: driver)
        try insertItemsBlocking(2, into: driver)

        #expect(
          updates.values
            == [
              .noEmission(source: .initial),
              .emitted(OrbitValueObservationChange(value: 1, source: .transaction(.local))),
              .noEmission(source: .transaction(.local))
            ]
        )
        #expect(errors.values.isEmpty)
        _ = subscription
      }

      @Test
      func compactMapSuppressesNilAndTransformsNonNilValues() throws {
        let driver = try blockingItemsDatabase()
        let recorder = ObservationRecorder<String>()
        let subscription = try OrbitValueObservation<Int?>
          .tracking { transaction in
            let count = try transaction.fetchOne(itemCountQuery)
            return count == 0 ? nil : count
          }
          .compactMap { $0.map { "count=\($0)" } }
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        #expect(recorder.changes.isEmpty)
        try insertItemsBlocking(1, into: driver)

        #expect(recorder.changes.map(\.value) == ["count=1"])
        #expect(recorder.changes.map(\.source) == [.transaction(.local)])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }

      @Test
      func operatorsRunInTheirWrittenOrder() throws {
        let driver = try blockingItemsDatabase()
        let transformCount = TestCounter()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation()
          .removeDuplicates(by: { _, _ in true })
          .map { value in
            transformCount.increment()
            return value
          }
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        try insertItemsBlocking(1, into: driver)

        #expect(recorder.changes.map(\.value) == [0])
        #expect(transformCount.value == 1)
        _ = subscription
      }

      @Test
      func throwingTransformEndsObservationAfterTheWriteCommits() throws {
        struct TransformError: Error {}

        let driver = try blockingItemsDatabase()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation()
          .map { value in
            if value > 0 { throw TransformError() }
            return value
          }
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        try insertItemsBlocking(1, into: driver)
        try insertItemsBlocking(2, into: driver)
        let count = try driver.readBlocking { transaction in
          try transaction.fetchOne(itemCountQuery)
        }

        #expect(count == 2)
        #expect(recorder.changes.map(\.value) == [0])
        #expect(recorder.errors.count == 1)
        _ = subscription
      }

      @Test
      func theSequencesBufferEveryPendingChangeByDefault() async throws {
        let driver = try await itemsDatabase()
        let changes = itemCountObservation().changes(in: driver)
        var iterator = changes.makeAsyncIterator()
        #expect(try await iterator.next()?.value == 0)

        for id in 1...3 {
          try await insertItems(id, into: driver)
        }

        #expect(try await iterator.next()?.value == 1)
        #expect(try await iterator.next()?.value == 2)
        #expect(try await iterator.next()?.value == 3)
      }

      @Test
      func bufferingModifierOverridesTheSequencePolicy() async throws {
        let driver = try await itemsDatabase()
        let values = itemCountObservation()
          .values(in: driver, bufferingPolicy: .bufferingNewest(1))
          .buffering(.unbounded)
        var iterator = values.makeAsyncIterator()
        #expect(try await iterator.next() == 0)

        for id in 1...2 {
          try await insertItems(id, into: driver)
        }

        #expect(try await iterator.next() == 1)
        #expect(try await iterator.next() == 2)
      }

      @Test
      func theSequenceStartsObservingWhenIterationBegins() async throws {
        let driver = try await itemsDatabase()
        let fetchCount = TestCounter()
        let values = itemCountObservation(countingFetchesIn: fetchCount)
          .values(in: driver)

        try await Task.sleep(for: .milliseconds(20))
        #expect(fetchCount.value == 0)

        var iterator = values.makeAsyncIterator()
        #expect(try await iterator.next() == 0)
        #expect(fetchCount.value == 1)
      }

      @Test(arguments: SupersededRefetch.allCases)
      func aRefetchControllerHandlesAReadSupersededByAnotherCommit(
        _ refetch: SupersededRefetch
      ) async throws {
        let queue = try await itemsDatabase()
        let driver = AnnouncingTestDatabase(queue)
        let value = Lock(0)
        let fetchCount = TestCounter()
        let gate = TestGate()
        let observation = refetch.apply(
          to: OrbitValueObservation<Int>
            .tracking(region: .fullDatabase) { _ in
              let count = fetchCount.increment()
              let fetched = value.withLock { $0 }
              if count == 2 { try gate.enter() }
              return fetched
            }
        )
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)

        value.withLock { $0 = 1 }
        driver.announceCommit(region: .fullDatabase)
        try await gate.waitUntilEntered()
        value.withLock { $0 = 2 }
        driver.announceCommit(region: .fullDatabase)
        gate.open()
        try await recorder.waitForChangeCount(2)
        for _ in 0..<100 { await Task.yield() }

        // `.immediate` retries the superseded read, where `.once` publishes it as it stands.
        switch refetch {
        case .immediate:
          #expect(recorder.changes.map(\.value) == [0, 2])
          #expect(fetchCount.value == 3)
        case .once:
          #expect(recorder.changes.map(\.value) == [0, 1])
          #expect(fetchCount.value == 2)
        }
        _ = subscription
      }

      @Test
      func coalescedRefetchControllerWaitsOnlyForAnActiveWriterCohort() async throws {
        let queue = try await itemsDatabase()
        let driver = AnnouncingTestDatabase(queue)
        let fetchCount = TestCounter()
        let observation = OrbitValueObservation<Int>
          .tracking(region: .fullDatabase) { _ in
            fetchCount.increment()
          }
          .refetching(.coalesced)
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)

        let activeWriter = SQLitePoolWriterBarrier(writerCount: 1)
        driver.setActiveWriters(activeWriter)
        driver.announceCommit(region: .fullDatabase)
        // The runtime captures coordination synchronously with the relevant commit, so a later
        // provider change cannot replace the cohort its controller must wait for.
        driver.setActiveWriters(nil)
        for _ in 0..<100 { await Task.yield() }
        #expect(fetchCount.value == 1)

        activeWriter.writerDidFinish()
        try await recorder.waitForChangeCount(2)
        driver.announceCommit(region: .fullDatabase)
        try await recorder.waitForChangeCount(3)

        #expect(fetchCount.value == 3)
        _ = subscription
      }

      @Test
      func customRefetchControllerReceivesRegionsReasonsAndTrackedRegion() async throws {
        let queue = try await itemsDatabase()
        let driver = AnnouncingTestDatabase(queue)
        let controller = RecordingRefetchController()
        let trackedRegion = OrbitDatabaseRegion(table: "items")
        let observation = OrbitValueObservation<Int>
          .tracking(region: trackedRegion) { _ in 0 }
          .refetching(controller)
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)

        driver.announceCommit(region: trackedRegion, origin: .external)
        try await controller.waitForSnapshot()
        let snapshot = try #require(controller.snapshots.first)

        #expect(snapshot.affectedRegion == trackedRegion)
        #expect(snapshot.trackedRegion == trackedRegion)
        #expect(snapshot.reasons == [.externalProcessChange])
        #expect(!snapshot.hasActiveWriters)
        _ = subscription
      }

      @Test
      func aControllerIsToldTheOriginOfEachCommitItIsCoalescing() async throws {
        let (database, peer, identifier) = try await announcingItemsDatabase("both-origins")
        let controller = CommitWaitingRefetchController(commitCount: 2)
        let subscription = try await subscribeTrackingItems(to: database, refetching: controller)

        try await database.writeWithoutTransaction { connection in
          try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
        }
        try await peer.send(
          commit(identifier, region: itemsRegion)
        )
        let snapshot = try await controller.snapshot()

        // A local write comes from this process, and one announced over the network from another.
        #expect(snapshot.commits.map(\.origin) == [.local, .external])
        #expect(snapshot.commits.allSatisfy { $0.region.overlaps(itemsRegion) })
        #expect(
          snapshot.commits.last == OrbitDatabaseCommit(origin: .external, region: itemsRegion)
        )
        #expect(snapshot.reasons == [.databaseChange, .externalProcessChange])
        _ = subscription
      }

      @Test
      func aControllerDoesNotSeeCommitsAnEarlierFetchAnswered() async throws {
        let (database, peer, identifier) = try await announcingItemsDatabase("answered-commits")
        let controller = CommitWaitingRefetchController(commitCount: 1)
        let subscription = try await subscribeTrackingItems(to: database, refetching: controller)

        try await peer.send(
          commit(identifier, region: itemsRegion)
        )
        _ = try await controller.snapshot()
        try await waitUntil { controller.fetchCount == 1 }
        controller.reset()
        try await database.writeWithoutTransaction { connection in
          try connection.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
        }
        let snapshot = try await controller.snapshot()

        #expect(snapshot.commits.map(\.origin) == [.local])
        _ = subscription
      }

      @Test
      func aControllerThatReturnsWithoutFetchingRunsAgainForAnInvalidationItMissed() async throws {
        let queue = try await itemsDatabase()
        let driver = AnnouncingTestDatabase(queue)
        let value = Lock(0)
        let controller = SkipFirstRefetchController()
        let observation = OrbitValueObservation<Int>
          .tracking(region: .fullDatabase) { _ in value.withLock { $0 } }
          .refetching(controller)
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)

        value.withLock { $0 = 1 }
        driver.announceCommit(region: .fullDatabase)
        try await controller.waitUntilSkipping()
        // Arrives while the controller is still running, so it cannot start one of its own.
        value.withLock { $0 = 2 }
        driver.announceCommit(region: .fullDatabase)
        controller.stopSkipping()

        try await recorder.waitForChangeCount(2)
        #expect(recorder.changes.map(\.value) == [0, 2])
        #expect(controller.runCount == 2)
        _ = subscription
      }

      @Test
      func aControllerThatNeverFetchesIsNotRunAgainForTheSameInvalidation() async throws {
        let queue = try await itemsDatabase()
        let driver = AnnouncingTestDatabase(queue)
        let controller = SkipFirstRefetchController(skipsEveryRun: true)
        let observation = OrbitValueObservation<Int>
          .tracking(region: .fullDatabase) { _ in 0 }
          .refetching(controller)
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
        try await recorder.waitForChangeCount(1)

        driver.announceCommit(region: .fullDatabase)
        try await controller.waitUntilSkipping()
        controller.stopSkipping()
        for _ in 0..<100 { await Task.yield() }

        #expect(controller.runCount == 1)
        #expect(recorder.changes.count == 1)
        _ = subscription
      }

      @Test
      func aControllerDoesNotSeeInvalidationsTheInitialFetchAlreadyAnswered() async throws {
        let queue = try await itemsDatabase()
        let driver = AnnouncingTestDatabase(queue)
        let fetchCount = TestCounter()
        let gate = TestGate()
        let controller = RecordingRefetchController()
        let trackedRegion = OrbitDatabaseRegion(table: "items")
        let observation = OrbitValueObservation<Int>
          .tracking(region: trackedRegion) { _ in
            let count = fetchCount.increment()
            if count == 1 { try gate.enter() }
            return count
          }
          .refetching(controller)
        let recorder = ObservationRecorder<Int>()
        let subscription = try observation.subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

        // Raised before the observation has an initial value, so the initial read answers it rather
        // than the controller.
        try await gate.waitUntilEntered()
        driver.announceCommit(region: trackedRegion, origin: .external)
        gate.open()
        try await recorder.waitForChangeCount(1)

        driver.announceCommit(region: trackedRegion)
        try await controller.waitForSnapshot()
        let snapshot = try #require(controller.snapshots.first)

        #expect(snapshot.reasons == [.databaseChange])
        #expect(snapshot.affectedRegion == trackedRegion)
        #expect(!snapshot.hasActiveWriters)
        _ = subscription
      }

      @Test
      func handleEventsReportsTheRuntimeLifecycle() async throws {
        let driver = try await itemsDatabase()
        let events = TestRecorder<String>()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation()
          .handleEvents(
            willStart: { events.append("willStart") },
            willFetch: { events.append("willFetch") },
            databaseDidChange: { events.append("databaseDidChange") },
            didReceiveValue: { value in events.append("didReceiveValue(\(value))") },
            didFail: { _ in events.append("didFail") },
            didCancel: { events.append("didCancel") }
          )
          .subscribe(
            to: driver,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        try await recorder.waitForChangeCount(1)
        #expect(events.values == ["willStart", "willFetch", "didReceiveValue(0)"])

        try await insertItems(1, into: driver)
        try await recorder.waitForChangeCount(2)
        // A local write is fetched inside its own transaction, so its fetch precedes the commit.
        #expect(
          events.values == [
            "willStart",
            "willFetch",
            "didReceiveValue(0)",
            "willFetch",
            "databaseDidChange",
            "didReceiveValue(1)"
          ]
        )

        subscription.cancel()
        #expect(events.values.last == "didCancel")
      }

      @Test
      func handleEventsSkipsFetchesTheObservationDoesNotMake() async throws {
        let driver = try await itemsDatabase()
        let events = TestRecorder<String>()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation()
          .filterTransactions { _ in false }
          .handleEvents(
            willFetch: { events.append("willFetch") },
            databaseDidChange: { events.append("databaseDidChange") }
          )
          .subscribe(
            to: driver,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        try await recorder.waitForChangeCount(1)
        try await insertItems(1, into: driver)

        #expect(events.values == ["willFetch"])
        #expect(recorder.changes.map(\.value) == [0])
        _ = subscription
      }

      @Test
      func handleEventsSurvivesDownstreamOperators() async throws {
        let driver = try await itemsDatabase()
        let values = TestRecorder<Int>()
        let recorder = ObservationRecorder<String>()
        let subscription = try itemCountObservation()
          .handleEvents(didReceiveValue: { value in values.append(value) })
          .map { "count=\($0)" }
          .subscribe(
            to: driver,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        try await recorder.waitForChangeCount(1)

        // The operator sees the value at its own position in the chain, before `map` runs.
        #expect(values.values == [0])
        #expect(recorder.changes.map(\.value) == ["count=0"])
        _ = subscription
      }

      @Test
      func aFetchErrorTerminatesTheSequenceAndIsReportedToHandleEvents() async throws {
        let driver = try SQLiteQueue(path: .memory)
        let failures = TestCounter()
        let values = itemCountObservation()
          .handleEvents(didFail: { _ in failures.increment() })
          .values(in: driver)
        var iterator = values.makeAsyncIterator()

        await #expect(throws: (any Error).self) {
          _ = try await iterator.next()
        }
        #expect(failures.value == 1)
      }

      @Test(arguments: [false, true])
      func aRegionSkipsUnrelatedLocalWrites(isExplicit: Bool) throws {
        let driver = try itemsAndNotesDatabase()
        let fetchCount = TestCounter()
        let recorder = ObservationRecorder<Int>()
        let subscription = try itemCountObservation(
          region: isExplicit ? itemsRegion : nil,
          countingFetchesIn: fetchCount
        )
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

        try driver.executeBlocking(sql: "INSERT INTO notes VALUES (1)")
        #expect(fetchCount.value == 1)
        #expect(recorder.changes.map(\.value) == [0])

        try driver.writeBlocking { transaction in
          transaction.notifyChanges(in: itemsRegion)
        }
        #expect(fetchCount.value == 2)
        #expect(recorder.changes.map(\.value) == [0, 0])

        try driver.executeBlocking(sql: "INSERT INTO items VALUES (1)")
        #expect(fetchCount.value == 3)
        #expect(recorder.changes.map(\.value) == [0, 0, 1])
        _ = subscription
      }

      @Test
      func automaticRegionRefreshesWhenSQLiteRecompilesACachedStatement() async throws {
        try await withPooledDatabase(configuration: .default, maximumReaderCount: 1) { database in
          try await database.execute(sql: currentItemsViewSchema)

          let recorder = ObservationRecorder<String?>()
          let subscription = try OrbitValueObservation<String?>
            .tracking { transaction in
              try transaction.fetchOne(
                #sql("SELECT title FROM current_items", as: String.self)
              )
            }
            .subscribe(
              to: database,
              onError: recorder.record(error:),
              onChange: recorder.record(change:)
            )
          try await recorder.waitForChangeCount(1)

          try await database.execute(sql: currentItemsViewRedefinition)
          try await recorder.waitForChangeCount(2)

          try await database.execute(sql: "UPDATE alternate_items SET title = 'Changed'")
          try await recorder.waitForChangeCount(3)

          #expect(recorder.changes.map(\.value) == ["Original", "Alternate", "Changed"])
          _ = subscription
        }
      }

      @Test
      func automaticRegionFollowsAViewRedefinedThroughAnotherConnection() async throws {
        try await withTestDatabaseFile("obs") { file in
          let identifier = OrbitDatabaseIdentifier(rawValue: "view-redefined-by-sibling-handle")
          var configuration = SQLiteConfiguration.default
          configuration.readerCount = 1
          let observingDatabase = OrbitIPCDatabase(
            writer: try file.pool(configuration: configuration),
            id: identifier,
            transport: InMemoryIPCTransport()
          )
          try await observingDatabase.execute(sql: currentItemsViewSchema)
          // The schema changes through a connection outside the pool, as another process's would.
          let writingDatabase = OrbitIPCDatabase(
            writer: try file.queue(),
            id: identifier,
            transport: InMemoryIPCTransport()
          )

          let recorder = ObservationRecorder<String?>()
          let subscription = try OrbitValueObservation<String?>
            .tracking { transaction in
              try transaction.fetchOne(#sql("SELECT title FROM current_items", as: String.self))
            }
            .subscribe(
              to: observingDatabase,
              onError: recorder.record(error:),
              onChange: recorder.record(change:)
            )
          try await recorder.waitForChangeCount(1)

          try await writingDatabase.execute(sql: currentItemsViewRedefinition)
          try await recorder.waitForChangeCount(2)

          try await writingDatabase.execute(sql: "UPDATE alternate_items SET title = 'Changed'")
          try await recorder.waitForChangeCount(3)

          #expect(recorder.changes.map(\.value) == ["Original", "Alternate", "Changed"])
          #expect(recorder.errors.isEmpty)
          _ = subscription
        }
      }

      @Test
      func automaticRegionFollowsTheReadsOfEachSuccessfulFetch() throws {
        let driver = try SQLiteQueue(path: .memory)
        try driver.executeBlocking(
          sql: """
            CREATE TABLE settings (useNotes INTEGER NOT NULL);
            CREATE TABLE items (id INTEGER PRIMARY KEY);
            CREATE TABLE notes (id INTEGER PRIMARY KEY);
            INSERT INTO settings VALUES (0);
            """
        )
        let fetchCount = TestCounter()
        let recorder = ObservationRecorder<Int>()
        let subscription = try OrbitValueObservation<Int>
          .tracking { transaction in
            fetchCount.increment()
            let useNotes =
              try transaction.fetchOne(
                #sql("SELECT useNotes FROM settings", as: Bool.self)
              ) ?? false
            let table = useNotes ? "notes" : "items"
            return try transaction.fetchOne(
              #sql("SELECT COUNT(*) FROM \(raw: table)", as: Int.self)
            ) ?? 0
          }
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        try driver.executeBlocking(sql: "INSERT INTO notes VALUES (1)")
        #expect(fetchCount.value == 1)

        try driver.executeBlocking(sql: "UPDATE settings SET useNotes = 1")
        #expect(recorder.changes.map(\.value) == [0, 1])

        try driver.executeBlocking(sql: "INSERT INTO items VALUES (1)")
        #expect(fetchCount.value == 2)

        try driver.executeBlocking(sql: "INSERT INTO notes VALUES (2)")
        #expect(fetchCount.value == 3)
        #expect(recorder.changes.map(\.value) == [0, 1, 2])
        _ = subscription
      }

      @Test
      func automaticRegionIncludesManuallyPublishedReads() throws {
        let driver = try SQLiteQueue(path: .memory)
        let fetchCount = TestCounter()
        let region = OrbitDatabaseRegion(table: "raw_items")
        let subscription = try OrbitValueObservation<Int>
          .tracking { transaction in
            fetchCount.increment()
            transaction.notifyReads(in: region)
            return 1
          }
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: { _ in },
            onChange: { _ in }
          )

        try driver.writeBlocking { transaction in
          transaction.notifyChanges(in: OrbitDatabaseRegion(table: "unrelated"))
        }
        #expect(fetchCount.value == 1)

        try driver.writeBlocking { transaction in
          transaction.notifyChanges(in: region)
        }
        #expect(fetchCount.value == 2)
        _ = subscription
      }

      @Test
      func rollbackClearsItsPublishedRegion() throws {
        let driver = try itemsAndNotesDatabase()
        let fetchCount = TestCounter()
        let subscription = try itemCountObservation(
          region: itemsRegion,
          countingFetchesIn: fetchCount
        )
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { _ in }
        )

        #expect(throws: TestError.self) {
          try driver.writeBlocking { transaction in
            try transaction.execute("INSERT INTO items VALUES (1)")
            throw TestError()
          }
        }
        try driver.executeBlocking(sql: "INSERT INTO notes VALUES (1)")

        #expect(fetchCount.value == 1)
        _ = subscription
      }

      @Test
      func trackingAllDerivesItsRegionFromTypedSQL() throws {
        let driver = try SQLiteQueue(path: .memory)
        try driver.executeBlocking(
          sql: """
            CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL, ignored TEXT);
            CREATE TABLE notes (id INTEGER PRIMARY KEY);
            INSERT INTO items VALUES (1, 'Before', NULL);
            """
        )
        let recorder = ObservationRecorder<[String]>()
        let observation = OrbitValueObservation.trackingAll(
          #sql("SELECT title FROM items ORDER BY id", as: String.self)
        )
        let subscription = try observation.subscribe(
          to: driver,
          scheduling: .immediate,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

        try driver.writeBlocking { transaction in
          try transaction.execute("UPDATE items SET ignored = 'Unobserved' WHERE id = 1")
          try transaction.execute("INSERT INTO notes VALUES (1)")
        }
        #expect(recorder.changes.map(\.value) == [["Before"]])

        try driver.executeBlocking(sql: "UPDATE items SET title = 'After' WHERE id = 1")
        #expect(recorder.changes.map(\.value) == [["Before"], ["After"]])
        #expect(recorder.errors.isEmpty)
        _ = subscription
      }

      @Test
      func trackingAllAndOneInferTypedQueryOutputs() throws {
        let driver = try SQLiteQueue(path: .memory)
        try driver.executeBlocking(
          sql: """
            CREATE TABLE observed_groups (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE TABLE observed_items (
              id INTEGER PRIMARY KEY,
              groupID INTEGER NOT NULL,
              title TEXT NOT NULL
            );
            INSERT INTO observed_groups VALUES (1, 'Group');
            INSERT INTO observed_items VALUES (1, 1, 'One'), (2, 1, 'Two');
            """
        )

        let all = OrbitValueObservation.trackingAll(ObservedItem.order { $0.id })
        let allRecorder = ObservationRecorder<[ObservedItem]>()
        let allSubscription = try all.subscribe(
          to: driver,
          scheduling: .immediate,
          onError: allRecorder.record(error:),
          onChange: allRecorder.record(change:)
        )

        let one = OrbitValueObservation.trackingOne(ObservedItem.where { $0.id.eq(2) })
        let oneRecorder = ObservationRecorder<ObservedItem?>()
        let oneSubscription = try one.subscribe(
          to: driver,
          scheduling: .immediate,
          onError: oneRecorder.record(error:),
          onChange: oneRecorder.record(change:)
        )

        let tuples = OrbitValueObservation.trackingAll(
          ObservedItem.order { $0.id }.select { ($0.id, $0.title) }
        )
        let tupleRecorder = ObservationRecorder<[(Int, String)]>()
        let tupleSubscription = try tuples.subscribe(
          to: driver,
          scheduling: .immediate,
          onError: tupleRecorder.record(error:),
          onChange: tupleRecorder.record(change:)
        )

        let joined = OrbitValueObservation.trackingAll(
          ObservedItem.join(ObservedGroup.all) { $0.groupID.eq($1.id) }
            .order { item, _ in item.id }
        )
        let joinedRecorder = ObservationRecorder<[(ObservedItem, ObservedGroup)]>()
        let joinedSubscription = try joined.subscribe(
          to: driver,
          scheduling: .immediate,
          onError: joinedRecorder.record(error:),
          onChange: joinedRecorder.record(change:)
        )

        #expect(allRecorder.changes.first?.value.map(\.title) == ["One", "Two"])
        #expect(oneRecorder.changes.first?.value?.title == "Two")
        #expect(tupleRecorder.changes.first?.value.map(\.0) == [1, 2])
        #expect(tupleRecorder.changes.first?.value.map(\.1) == ["One", "Two"])
        #expect(joinedRecorder.changes.first?.value.map { $0.1.name } == ["Group", "Group"])
        #expect(allRecorder.errors.isEmpty)
        #expect(oneRecorder.errors.isEmpty)
        #expect(tupleRecorder.errors.isEmpty)
        #expect(joinedRecorder.errors.isEmpty)
        _ = (allSubscription, oneSubscription, tupleSubscription, joinedSubscription)
      }

      @Test
      func queryFragmentTrackingOneObservesAnOptionalValue() throws {
        let driver = try SQLiteQueue(path: .memory)
        try driver.executeBlocking(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT)")
        let query: QueryFragment = "SELECT title FROM items ORDER BY id LIMIT 1"
        let recorder = ObservationRecorder<String?>()
        let subscription =
          try OrbitValueObservation
          .trackingOne(query, as: String.self)
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        #expect(recorder.changes.map(\.value) == [nil])
        try driver.executeBlocking(sql: "INSERT INTO items VALUES (1, 'One')")
        #expect(recorder.changes.map(\.value) == [nil, "One"])
        _ = subscription
      }

      @Test
      func emptyQueryRegionDoesNotRefetch() throws {
        let driver = try blockingItemsDatabase()
        let recorder = ObservationRecorder<Int?>()
        let subscription =
          try OrbitValueObservation
          .trackingOne(#sql("SELECT 1", as: Int.self))
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        try driver.executeBlocking(sql: "INSERT INTO items VALUES (1)")
        #expect(recorder.changes.map(\.value) == [1])
        _ = subscription
      }

      @Test
      func queryObservationConservativelyRefetchesAfterExternalCommit() async throws {
        let (database, peer, identifier) = try await announcingItemsDatabase("query-external")
        let changes =
          OrbitValueObservation
          .trackingAll(#sql("SELECT id FROM items", as: Int.self))
          .changes(in: database)
        var iterator = changes.makeAsyncIterator()

        #expect(try await iterator.next()?.source == .initial)
        try await peer.send(
          commit(identifier, region: .fullDatabase)
        )
        #expect(try await iterator.next()?.source == .transaction(.external))
      }

      @Test
      func writableTypedSQLIsRejectedBeforeItExecutes() throws {
        let driver = try SQLiteQueue(path: .memory)
        try driver.writeBlocking { transaction in
          try transaction.executeScript(
            "CREATE TABLE items (id INTEGER PRIMARY KEY); INSERT INTO items VALUES (1)"
          )
        }
        let recorder = ObservationRecorder<[Int]>()
        let subscription =
          try OrbitValueObservation
          .trackingAll(#sql("DELETE FROM items RETURNING id", as: Int.self))
          .subscribe(
            to: driver,
            scheduling: .immediate,
            onError: recorder.record(error:),
            onChange: recorder.record(change:)
          )

        let count = try driver.readBlocking { transaction in
          try transaction.fetchOne(itemCountQuery)
        }
        #expect(count == 1)
        #expect(recorder.changes.isEmpty)
        #expect(recorder.errors.count == 1)
        _ = subscription
      }
    }

    enum SupersededRefetch: CaseIterable, Sendable {
      case immediate, once

      fileprivate func apply(to observation: OrbitValueObservation<Int>) -> OrbitValueObservation<
        Int
      > {
        switch self {
        case .immediate: observation.refetching(.immediate)
        case .once: observation.refetching(.once)
        }
      }
    }

    @Table("observed_items")
    private struct ObservedItem: Equatable {
      let id: Int
      var groupID: Int
      var title: String
    }

    @Table("observed_groups")
    private struct ObservedGroup: Equatable {
      let id: Int
      var name: String
    }

    /// A database with an items table and a notes table no items observation reads.
    private func itemsAndNotesDatabase() throws -> SQLiteQueue {
      let driver = try blockingItemsDatabase()
      try driver.executeBlocking(sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY)")
      return driver
    }

    private func itemCountObservation() -> OrbitValueObservation<Int> {
      OrbitValueObservation.tracking { transaction in
        try transaction.fetchOne(itemCountQuery) ?? 0
      }
    }

    /// ``itemCountObservation()``, counting its fetches in `fetchCount`, and watching `region` rather
    /// than what each fetch reads when one is given.
    private func itemCountObservation(
      region: OrbitDatabaseRegion? = nil,
      countingFetchesIn fetchCount: TestCounter
    ) -> OrbitValueObservation<Int> {
      let fetch: @Sendable (borrowing SQLiteReadTransaction) throws -> Int = { transaction in
        fetchCount.increment()
        return try transaction.fetchOne(itemCountQuery) ?? 0
      }
      guard let region else { return .tracking(fetch) }
      return .tracking(region: region, fetch)
    }

    /// Records what an observation delivers to a subscriber, as its `onChange` and `onError`.
    private final class ObservationRecorder<Value: Sendable>: Sendable {
      private let recordedChanges = TestRecorder<OrbitValueObservationChange<Value>>()
      private let recordedErrors = TestRecorder<String>()

      var changes: [OrbitValueObservationChange<Value>] { self.recordedChanges.values }
      var errors: [String] { self.recordedErrors.values }

      func record(change: OrbitValueObservationChange<Value>) {
        self.recordedChanges.append(change)
      }

      func record(error: any Error) {
        self.recordedErrors.append(String(describing: error))
      }

      func waitForChangeCount(_ count: Int) async throws {
        try await self.recordedChanges.waitForCount(count)
      }
    }

    private final class RecordingRefetchController: OrbitValueObservationRefetchController, Sendable
    {
      private let recordedSnapshots = TestRecorder<OrbitValueObservationRefetchSnapshot>()

      var snapshots: [OrbitValueObservationRefetchSnapshot] { self.recordedSnapshots.values }

      func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
        var context = context
        self.recordedSnapshots.append(context.snapshot())
        await context.fetch(publishing: .force)
      }

      func waitForSnapshot() async throws {
        try await self.recordedSnapshots.waitForCount(1)
      }
    }

    /// A controller that waits for a given number of commits to accumulate before it records a
    /// snapshot and fetches, so that commits arriving one after another are seen together.
    private final class CommitWaitingRefetchController:
      OrbitValueObservationRefetchController, Sendable
    {
      private let commitCount: Int
      private let recorded = Lock<OrbitValueObservationRefetchSnapshot?>(nil)
      private let fetches = TestCounter()

      init(commitCount: Int) {
        self.commitCount = commitCount
      }

      var fetchCount: Int { fetches.value }

      func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
        var context = context
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while context.snapshot().commits.count < commitCount, clock.now < deadline {
          try? await Task.sleep(for: .milliseconds(2))
        }
        let snapshot = context.snapshot()
        recorded.withLock { $0 = snapshot }
        await context.fetch(publishing: .force)
        fetches.increment()
      }

      func snapshot() async throws -> OrbitValueObservationRefetchSnapshot {
        try await waitUntil(timeout: .seconds(10)) { self.recorded.withLock { $0 != nil } }
        return try #require(recorded.withLock { $0 })
      }

      func reset() {
        recorded.withLock { $0 = nil }
      }
    }

    /// A database that announces over an in-memory network, and a transport on that network that
    /// stands in for another process's database.
    private func announcingItemsDatabase(
      _ name: String
    ) async throws -> (OrbitIPCDatabase, InMemoryIPCTransport, OrbitDatabaseIdentifier) {
      let network = InMemoryIPCTransport.Network()
      let identifier = OrbitDatabaseIdentifier(rawValue: name)
      let database = OrbitIPCDatabase(
        writer: try await itemsDatabase(),
        id: identifier,
        transport: InMemoryIPCTransport(network: network)
      )
      return (database, InMemoryIPCTransport(network: network), identifier)
    }

    /// Subscribes an observation of the items table, returning once its initial value is in.
    private func subscribeTrackingItems(
      to database: OrbitIPCDatabase,
      refetching controller: some OrbitValueObservationRefetchController
    ) async throws -> OrbitSubscription {
      let observation = OrbitValueObservation<Int>
        .tracking(region: itemsRegion) { _ in 0 }
        .refetching(controller)
      let recorder = ObservationRecorder<Int>()
      let subscription = try observation.subscribe(
        to: database,
        onError: recorder.record(error:),
        onChange: recorder.record(change:)
      )
      try await recorder.waitForChangeCount(1)
      return subscription
    }

    private let itemsRegion = OrbitDatabaseRegion(table: "items")

    /// A controller that returns without a conclusive fetch until it is told to stop doing so.
    private final class SkipFirstRefetchController:
      OrbitValueObservationRefetchController, Sendable
    {
      private struct State: Sendable {
        var runCount = 0
        var isSkipping = false
        var skipsEveryRun: Bool
      }

      private let state: Lock<State>

      init(skipsEveryRun: Bool = false) {
        self.state = Lock(State(skipsEveryRun: skipsEveryRun))
      }

      var runCount: Int { state.withLock { $0.runCount } }

      func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
        let skips = state.withLock { state -> Bool in
          state.runCount += 1
          let skips = state.skipsEveryRun || state.runCount == 1
          state.isSkipping = skips
          return skips
        }
        guard !skips else {
          while state.withLock({ $0.isSkipping }) { await Task.yield() }
          return
        }
        var context = context
        while await context.fetch(publishing: .ifCurrent) == .superseded {}
      }

      func waitUntilSkipping() async throws {
        try await waitUntil(timeout: .seconds(5)) { self.state.withLock { $0.isSkipping } }
      }

      func stopSkipping() {
        state.withLock { $0.isSkipping = false }
      }
    }

    @MainActor
    private final class MainActorObservationRecorder<Value: Sendable> {
      var changes = [OrbitValueObservationChange<Value>]()
      var errors = [String]()

      func waitForChangeCount(_ count: Int) async throws {
        try await waitUntil(timeout: .seconds(5)) { self.changes.count >= count }
      }
    }
  #endif
#endif
