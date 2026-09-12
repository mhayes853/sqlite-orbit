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
      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      try await recorder.waitForChangeCount(2)

      #expect(recorder.changes.map(\.value) == [0, 1])
      #expect(recorder.changes.map(\.source) == [.initial, .transaction(.local)])
      #expect(recorder.errors.isEmpty)
      _ = subscription
    }

    @Test
    func immediateSchedulerDeliversInitialValueBeforeSubscribeReturns() async throws {
      let driver = try await itemsDatabase()
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
      #expect(recorder.errors.isEmpty)
      _ = subscription
    }

    @Test
    func immediateSchedulerIntroducesNoBoundaryForCommittedValues() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let recorder = ObservationRecorder<Int>()
      let subscription = try itemCountObservation()
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

      try driver.writeBlocking { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(recorder.changes.map(\.value) == [0, 1])
      _ = subscription
    }

    @Test
    func immediateSchedulerWorksThroughOrbitDatabase() async throws {
      let driver = try await itemsDatabase()
      let database = OrbitDatabase(writer: driver)
      let recorder = ObservationRecorder<Int>()

      let subscription = try itemCountObservation()
        .subscribe(
          to: database,
          scheduling: .immediate,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

      #expect(recorder.changes.map(\.value) == [0])
      _ = subscription
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

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
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
      struct Abort: Error {}

      let driver = try await itemsDatabase()
      let recorder = ObservationRecorder<Int>()
      let subscription = try itemCountObservation()
        .subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
      try await recorder.waitForChangeCount(1)

      await #expect(throws: Abort.self) {
        try await driver.write { transaction in
          try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
          throw Abort()
        }
      }
      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
      }
      try await recorder.waitForChangeCount(2)

      #expect(recorder.changes.map(\.value) == [0, 1])
      _ = subscription
    }

    @Test
    func commitFailureDiscardsThePendingValue() async throws {
      let driver = try SQLiteQueue(path: .memory)
      try await driver.write { transaction in
        try transaction.execute(
          """
          CREATE TABLE parents (id INTEGER PRIMARY KEY);
          CREATE TABLE children (
            parent_id INTEGER NOT NULL REFERENCES parents(id)
              DEFERRABLE INITIALLY DEFERRED
          );
          """
        )
      }
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

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      let local = try #require(try await iterator.next())
      #expect(local.value == 1)
      #expect(local.source == .transaction(.local))
    }

    @Test
    func interprocessObservationRefetchesWithExternalSource() async throws {
      let driver = try await itemsDatabase()
      let network = InMemoryIPCTransport.Network()
      let receivingTransport = InMemoryIPCTransport(network: network)
      let sendingTransport = InMemoryIPCTransport(network: network)
      let identifier = OrbitDatabaseIdentifier(rawValue: "external-observation")
      let database = OrbitDatabase(
        writer: driver,
        id: identifier,
        transport: receivingTransport
      )
      let changes = itemCountObservation().changes(in: database)
      var iterator = changes.makeAsyncIterator()

      let initial = try #require(try await iterator.next())
      #expect(initial.source == .initial)

      try await sendingTransport.send(
        .transactionDidCommit(.init(databaseIdentifier: identifier, region: .fullDatabase))
      )
      let external = try #require(try await iterator.next())
      #expect(external.value == 0)
      #expect(external.source == .transaction(.external))
    }

    @Test
    func interprocessObservationIgnoresDisjointRegions() async throws {
      let driver = try await itemsDatabase()
      let network = InMemoryIPCTransport.Network()
      let receivingTransport = InMemoryIPCTransport(network: network)
      let sendingTransport = InMemoryIPCTransport(network: network)
      let identifier = OrbitDatabaseIdentifier(rawValue: "external-region-filtering")
      let database = OrbitDatabase(
        writer: driver,
        id: identifier,
        transport: receivingTransport
      )
      let fetchCount = Lock(0)
      let observation = OrbitValueObservation<Int>
        .tracking(region: OrbitDatabaseRegion(table: "items")) { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
      let recorder = ObservationRecorder<Int>()
      let subscription = try observation.subscribe(
        to: database,
        onError: recorder.record(error:),
        onChange: recorder.record(change:)
      )
      try await recorder.waitForChangeCount(1)

      try await sendingTransport.send(
        .transactionDidCommit(.init(databaseIdentifier: identifier, region: .empty))
      )
      #expect(fetchCount.withLock { $0 } == 1)

      try await sendingTransport.send(
        .transactionDidCommit(
          .init(
            databaseIdentifier: identifier,
            region: OrbitDatabaseRegion(table: "unrelated")
          )
        )
      )
      #expect(fetchCount.withLock { $0 } == 1)

      try await sendingTransport.send(
        .transactionDidCommit(
          .init(databaseIdentifier: identifier, region: OrbitDatabaseRegion(table: "items"))
        )
      )
      try await recorder.waitForChangeCount(2)

      #expect(fetchCount.withLock { $0 } == 2)
      #expect(recorder.changes.map(\.source) == [.initial, .transaction(.external)])
      _ = subscription
    }

    @Test
    func transactionFilterUsesTheCommitOriginBeforeFetching() async throws {
      let driver = try await itemsDatabase()
      let network = InMemoryIPCTransport.Network()
      let receivingTransport = InMemoryIPCTransport(network: network)
      let sendingTransport = InMemoryIPCTransport(network: network)
      let identifier = OrbitDatabaseIdentifier(rawValue: "filtered-observation")
      let database = OrbitDatabase(
        writer: driver,
        id: identifier,
        transport: receivingTransport
      )
      let fetchCount = Lock(0)
      let observation = OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
        .filterTransactions { $0.origin == .external }
      let recorder = ObservationRecorder<Int>()
      let subscription = try observation.subscribe(
        to: database,
        onError: recorder.record(error:),
        onChange: recorder.record(change:)
      )
      try await recorder.waitForChangeCount(1)

      try await database.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      #expect(fetchCount.withLock { $0 } == 1)

      try await sendingTransport.send(
        .transactionDidCommit(.init(databaseIdentifier: identifier, region: .fullDatabase))
      )
      try await recorder.waitForChangeCount(2)

      #expect(fetchCount.withLock { $0 } == 2)
      #expect(recorder.changes.map(\.value) == [0, 1])
      #expect(recorder.changes.map(\.source) == [.initial, .transaction(.external)])
      _ = subscription
    }

    @Test
    func transactionFilterReceivesThePreviousAcceptedValue() async throws {
      let driver = try await itemsDatabase()
      let previousValues = Lock([Int?]())
      let fetchCount = Lock(0)
      let observation = OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
        .removeDuplicates(by: { _, _ in true })
        .filterTransactions { _, previousValue in
          previousValues.withLock { $0.append(previousValue) }
          return true
        }
      let recorder = ObservationRecorder<Int>()
      let subscription = try observation.subscribe(
        to: driver,
        onError: recorder.record(error:),
        onChange: recorder.record(change:)
      )
      try await recorder.waitForChangeCount(1)

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
      }

      #expect(previousValues.withLock { $0 } == [0, 0])
      #expect(fetchCount.withLock { $0 } == 3)
      #expect(recorder.changes.map(\.value) == [0])
      _ = subscription
    }

    @Test
    func interprocessObservationSeesSiblingHandleWriteAsLocal() async throws {
      let directory = try makeShortTemporaryDirectory("obs")
      defer { try? FileManager.default.removeItem(at: directory) }

      let path = OrbitDatabasePath.file(directory.appending(component: "database.sqlite"))
      let identifier = OrbitDatabaseIdentifier(rawValue: "same-process-observation")
      let writingDatabase = OrbitDatabase(
        writer: try SQLiteQueue(path: path),
        id: identifier
      )
      try await writingDatabase.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observingDatabase = OrbitDatabase(
        writer: try SQLiteQueue(path: path),
        id: identifier
      )
      let recorder = ObservationRecorder<Int>()
      let subscription = try itemCountObservation()
        .subscribe(
          to: observingDatabase,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )
      try await recorder.waitForChangeCount(1)

      try await writingDatabase.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      try await recorder.waitForChangeCount(2)

      #expect(recorder.changes.map(\.value) == [0, 1])
      #expect(recorder.changes.map(\.source) == [.initial, .transaction(.local)])
      _ = subscription
    }

    @Test
    func interprocessObservationIgnoresDisjointSiblingHandleWrites() async throws {
      let directory = try makeShortTemporaryDirectory("obs")
      defer { try? FileManager.default.removeItem(at: directory) }

      let path = OrbitDatabasePath.file(directory.appending(component: "database.sqlite"))
      let identifier = OrbitDatabaseIdentifier(rawValue: "same-process-region-filtering")
      let writingDatabase = OrbitDatabase(writer: try SQLiteQueue(path: path), id: identifier)
      try await writingDatabase.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observingDatabase = OrbitDatabase(writer: try SQLiteQueue(path: path), id: identifier)
      let fetchCount = Lock(0)
      let observation = OrbitValueObservation<Int>
        .tracking(region: OrbitDatabaseRegion(table: "items")) { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
      let recorder = ObservationRecorder<Int>()
      let subscription = try observation.subscribe(
        to: observingDatabase,
        onError: recorder.record(error:),
        onChange: recorder.record(change:)
      )
      try await recorder.waitForChangeCount(1)

      try await writingDatabase.write { transaction in
        transaction.notifyChanges(in: OrbitDatabaseRegion(table: "unrelated"))
      }
      #expect(fetchCount.withLock { $0 } == 1)

      try await writingDatabase.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      try await recorder.waitForChangeCount(2)

      #expect(fetchCount.withLock { $0 } == 2)
      #expect(recorder.changes.map(\.source) == [.initial, .transaction(.local)])
      _ = subscription
    }

    @Test
    func cancellingValueSubscriptionStopsRefetching() async throws {
      let driver = try await itemsDatabase()
      let fetchCount = Lock(0)
      let observation = OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
      let recorder = ObservationRecorder<Int>()
      let subscription = try observation.subscribe(
        to: driver,
        onError: recorder.record(error:),
        onChange: recorder.record(change:)
      )
      try await recorder.waitForChangeCount(1)
      subscription.cancel()

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(fetchCount.withLock { $0 } == 1)
    }

    @Test
    func subscribersShareOneRuntimeAndFetch() async throws {
      let driver = try await itemsDatabase()
      let fetchCount = Lock(0)
      let observation = OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
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
      #expect(fetchCount.withLock { $0 } == 1)

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      try await first.waitForChangeCount(2)
      try await second.waitForChangeCount(2)

      #expect(first.changes.map(\.value) == [0, 1])
      #expect(second.changes.map(\.value) == [0, 1])
      #expect(fetchCount.withLock { $0 } == 2)
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
      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(try await iterator.next()?.value == 1)
    }

    @Test
    func mapTransformsValuesAndPreservesTheirSources() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let recorder = ObservationRecorder<String>()
      let subscription = try itemCountObservation()
        .map { "count=\($0)" }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

      try driver.writeBlocking { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(recorder.changes.map(\.value) == ["count=0", "count=1"])
      #expect(recorder.changes.map(\.source) == [.initial, .transaction(.local)])
      #expect(recorder.errors.isEmpty)
      _ = subscription
    }

    @Test
    func filterSuppressesValuesWithoutRepeatingTheSharedInitialFetch() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let fetchCount = Lock(0)
      let observation = OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
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
      #expect(fetchCount.withLock { $0 } == 1)

      try driver.writeBlocking { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(first.changes.map(\.value) == [1])
      #expect(second.changes.map(\.value) == [1])
      #expect(first.changes.map(\.source) == [.transaction(.local)])
      #expect(fetchCount.withLock { $0 } == 2)
      _ = subscriptions
    }

    @Test
    func compactMapSuppressesNilAndTransformsNonNilValues() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let recorder = ObservationRecorder<String>()
      let subscription = try OrbitValueObservation<Int?>
        .tracking { transaction in
          let count = try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self))
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
      try driver.writeBlocking { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(recorder.changes.map(\.value) == ["count=1"])
      #expect(recorder.changes.map(\.source) == [.transaction(.local)])
      #expect(recorder.errors.isEmpty)
      _ = subscription
    }

    @Test
    func operatorsRunInTheirWrittenOrder() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let transformCount = Lock(0)
      let recorder = ObservationRecorder<Int>()
      let subscription = try itemCountObservation()
        .removeDuplicates(by: { _, _ in true })
        .map { value in
          transformCount.withLock { $0 += 1 }
          return value
        }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

      try driver.writeBlocking { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(recorder.changes.map(\.value) == [0])
      #expect(transformCount.withLock { $0 } == 1)
      _ = subscription
    }

    @Test
    func throwingTransformEndsObservationAfterTheWriteCommits() throws {
      struct TransformError: Error {}

      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
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

      try driver.writeBlocking { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      try driver.writeBlocking { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (2)", as: Void.self))
      }
      let count = try driver.readBlocking { transaction in
        try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self))
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
        try await driver.write { transaction in
          try transaction.execute(
            #sql("INSERT INTO items (id) VALUES (\(bind: id))", as: Void.self)
          )
        }
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
        try await driver.write { transaction in
          try transaction.execute(
            #sql("INSERT INTO items (id) VALUES (\(bind: id))", as: Void.self)
          )
        }
      }

      #expect(try await iterator.next() == 1)
      #expect(try await iterator.next() == 2)
    }

    @Test
    func theSequenceStartsObservingWhenIterationBegins() async throws {
      let driver = try await itemsDatabase()
      let fetchCount = Lock(0)
      let values = OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
        .values(in: driver)

      try await Task.sleep(for: .milliseconds(20))
      #expect(fetchCount.withLock { $0 } == 0)

      var iterator = values.makeAsyncIterator()
      #expect(try await iterator.next() == 0)
      #expect(fetchCount.withLock { $0 } == 1)
    }

    @Test
    func immediateRefetchPolicyRetriesAReadSupersededByAnotherCommit() async throws {
      let queue = try await itemsDatabase()
      let driver = PostCommitObservableDatabase(queue)
      let value = Lock(0)
      let fetchCount = Lock(0)
      let gate = FetchGate()
      let observation = OrbitValueObservation<Int>
        .tracking(region: .fullDatabase) { _ in
          let count = fetchCount.withLock { count in
            count += 1
            return count
          }
          let fetched = value.withLock { $0 }
          if count == 2 { gate.hold() }
          return fetched
        }
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

      #expect(recorder.changes.map(\.value) == [0, 2])
      #expect(fetchCount.withLock { $0 } == 3)
      _ = subscription
    }

    @Test
    func onceRefetchPolicyPublishesItsSingleFetchWhenSuperseded() async throws {
      let queue = try await itemsDatabase()
      let driver = PostCommitObservableDatabase(queue)
      let value = Lock(0)
      let fetchCount = Lock(0)
      let gate = FetchGate()
      let observation = OrbitValueObservation<Int>
        .tracking(region: .fullDatabase) { _ in
          let count = fetchCount.withLock { count in
            count += 1
            return count
          }
          let fetched = value.withLock { $0 }
          if count == 2 { gate.hold() }
          return fetched
        }
        .refetching(.once)
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

      #expect(recorder.changes.map(\.value) == [0, 1])
      #expect(fetchCount.withLock { $0 } == 2)
      _ = subscription
    }

    @Test
    func coalescedRefetchPolicyWaitsOnlyForAnActiveWriterCohort() async throws {
      let queue = try await itemsDatabase()
      let driver = PostCommitObservableDatabase(queue)
      let fetchCount = Lock(0)
      let observation = OrbitValueObservation<Int>
        .tracking(region: .fullDatabase) { _ in fetchCount.withLock { $0 += 1; return $0 } }
        .refetching(.coalesced)
      let recorder = ObservationRecorder<Int>()
      let subscription = try observation.subscribe(
        to: driver,
        onError: recorder.record(error:),
        onChange: recorder.record(change:)
      )
      try await recorder.waitForChangeCount(1)

      let activeWriter = SQLitePoolWriterBarrier(writerCount: 1)
      driver.announceCommit(region: .fullDatabase, activeWriterBarrier: activeWriter)
      for _ in 0..<100 { await Task.yield() }
      #expect(fetchCount.withLock { $0 } == 1)

      activeWriter.writerDidFinish()
      try await recorder.waitForChangeCount(2)
      driver.announceCommit(
        region: .fullDatabase,
        activeWriterBarrier: SQLitePoolWriterBarrier(writerCount: 0)
      )
      try await recorder.waitForChangeCount(3)

      #expect(fetchCount.withLock { $0 } == 3)
      _ = subscription
    }

    @Test
    func customRefetchPolicyReceivesRegionsReasonsAndTrackedRegion() async throws {
      let queue = try await itemsDatabase()
      let driver = PostCommitObservableDatabase(queue)
      let policy = RecordingRefetchPolicy()
      let trackedRegion = OrbitDatabaseRegion(table: "items")
      let observation = OrbitValueObservation<Int>
        .tracking(region: trackedRegion) { _ in 0 }
        .refetching(policy)
      let recorder = ObservationRecorder<Int>()
      let subscription = try observation.subscribe(
        to: driver,
        onError: recorder.record(error:),
        onChange: recorder.record(change:)
      )
      try await recorder.waitForChangeCount(1)

      driver.announceCommit(region: trackedRegion, origin: .external)
      try await policy.waitForSnapshot()
      let snapshot = try #require(policy.snapshots.first)

      #expect(snapshot.affectedRegion == trackedRegion)
      #expect(snapshot.trackedRegion == trackedRegion)
      #expect(snapshot.reasons == [.externalProcessChange])
      #expect(!snapshot.hasActiveWriters)
      _ = subscription
    }

    @Test
    func handleEventsReportsTheRuntimeLifecycle() async throws {
      let driver = try await itemsDatabase()
      let events = Lock([String]())
      let recorder = ObservationRecorder<Int>()
      let subscription = try itemCountObservation()
        .handleEvents(
          willStart: { events.withLock { $0.append("willStart") } },
          willFetch: { events.withLock { $0.append("willFetch") } },
          databaseDidChange: { events.withLock { $0.append("databaseDidChange") } },
          didReceiveValue: { value in events.withLock { $0.append("didReceiveValue(\(value))") } },
          didFail: { _ in events.withLock { $0.append("didFail") } },
          didCancel: { events.withLock { $0.append("didCancel") } }
        )
        .subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

      try await recorder.waitForChangeCount(1)
      #expect(events.withLock { $0 } == ["willStart", "willFetch", "didReceiveValue(0)"])

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }
      try await recorder.waitForChangeCount(2)
      // A local write is fetched inside its own transaction, so its fetch precedes the commit.
      #expect(
        events.withLock { $0 } == [
          "willStart",
          "willFetch",
          "didReceiveValue(0)",
          "willFetch",
          "databaseDidChange",
          "didReceiveValue(1)"
        ]
      )

      subscription.cancel()
      #expect(events.withLock { $0 }.last == "didCancel")
    }

    @Test
    func handleEventsSkipsFetchesTheObservationDoesNotMake() async throws {
      let driver = try await itemsDatabase()
      let events = Lock([String]())
      let recorder = ObservationRecorder<Int>()
      let subscription = try itemCountObservation()
        .filterTransactions { _ in false }
        .handleEvents(
          willFetch: { events.withLock { $0.append("willFetch") } },
          databaseDidChange: { events.withLock { $0.append("databaseDidChange") } }
        )
        .subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

      try await recorder.waitForChangeCount(1)
      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(events.withLock { $0 } == ["willFetch"])
      #expect(recorder.changes.map(\.value) == [0])
      _ = subscription
    }

    @Test
    func handleEventsSurvivesDownstreamOperators() async throws {
      let driver = try await itemsDatabase()
      let values = Lock([Int]())
      let recorder = ObservationRecorder<String>()
      let subscription = try itemCountObservation()
        .handleEvents(didReceiveValue: { value in values.withLock { $0.append(value) } })
        .map { "count=\($0)" }
        .subscribe(
          to: driver,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

      try await recorder.waitForChangeCount(1)

      // The operator sees the value at its own position in the chain, before `map` runs.
      #expect(values.withLock { $0 } == [0])
      #expect(recorder.changes.map(\.value) == ["count=0"])
      _ = subscription
    }

    @Test
    func handleEventsReportsAFetchFailure() async throws {
      let driver = try SQLiteQueue(path: .memory)
      let failures = Lock(0)
      let values = itemCountObservation()
        .handleEvents(didFail: { _ in failures.withLock { $0 += 1 } })
        .values(in: driver)
      var iterator = values.makeAsyncIterator()

      await #expect(throws: (any Error).self) {
        _ = try await iterator.next()
      }
      #expect(failures.withLock { $0 } == 1)
    }

    @Test
    func fetchErrorTerminatesTheAsyncSequence() async throws {
      let driver = try SQLiteQueue(path: .memory)
      let values = itemCountObservation().values(in: driver)
      var iterator = values.makeAsyncIterator()

      await #expect(throws: (any Error).self) {
        _ = try await iterator.next()
      }
    }

    @Test
    func explicitRegionSkipsUnrelatedLocalWrites() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute(
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY);
          CREATE TABLE notes (id INTEGER PRIMARY KEY);
          """
        )
      }
      let fetchCount = Lock(0)
      let recorder = ObservationRecorder<Int>()
      let subscription = try OrbitValueObservation<Int>
        .tracking(region: OrbitDatabaseRegion(table: "items")) { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO notes VALUES (1)")
      }
      #expect(fetchCount.withLock { $0 } == 1)
      #expect(recorder.changes.map(\.value) == [0])

      try driver.writeBlocking { transaction in
        transaction.notifyChanges(in: OrbitDatabaseRegion(table: "items"))
      }
      #expect(fetchCount.withLock { $0 } == 2)
      #expect(recorder.changes.map(\.value) == [0, 0])

      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO items VALUES (1)")
      }
      #expect(fetchCount.withLock { $0 } == 3)
      #expect(recorder.changes.map(\.value) == [0, 0, 1])
      _ = subscription
    }

    @Test
    func automaticRegionSkipsUnrelatedLocalWrites() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute(
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY);
          CREATE TABLE notes (id INTEGER PRIMARY KEY);
          """
        )
      }
      let fetchCount = Lock(0)
      let recorder = ObservationRecorder<Int>()
      let subscription = try OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: recorder.record(error:),
          onChange: recorder.record(change:)
        )

      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO notes VALUES (1)")
      }
      #expect(fetchCount.withLock { $0 } == 1)

      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO items VALUES (1)")
      }
      #expect(fetchCount.withLock { $0 } == 2)
      #expect(recorder.changes.map(\.value) == [0, 1])
      _ = subscription
    }

    @Test
    func automaticRegionRefreshesWhenSQLiteRecompilesACachedStatement() async throws {
      try await withPooledDatabase(configuration: .default, maximumReaderCount: 1) { database in
        try await database.write { transaction in
          try transaction.execute(
            """
            CREATE TABLE original_items (title TEXT NOT NULL);
            CREATE TABLE alternate_items (title TEXT NOT NULL);
            INSERT INTO original_items VALUES ('Original');
            INSERT INTO alternate_items VALUES ('Alternate');
            CREATE VIEW current_items AS SELECT title FROM original_items;
            """
          )
        }

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

        try await database.write { transaction in
          try transaction.execute(
            """
            DROP VIEW current_items;
            CREATE VIEW current_items AS SELECT title FROM alternate_items;
            """
          )
        }
        try await recorder.waitForChangeCount(2)

        try await database.write { transaction in
          try transaction.execute("UPDATE alternate_items SET title = 'Changed'")
        }
        try await recorder.waitForChangeCount(3)

        #expect(recorder.changes.map(\.value) == ["Original", "Alternate", "Changed"])
        _ = subscription
      }
    }

    @Test
    func automaticRegionFollowsTheReadsOfEachSuccessfulFetch() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute(
          """
          CREATE TABLE settings (useNotes INTEGER NOT NULL);
          CREATE TABLE items (id INTEGER PRIMARY KEY);
          CREATE TABLE notes (id INTEGER PRIMARY KEY);
          INSERT INTO settings VALUES (0);
          """
        )
      }
      let fetchCount = Lock(0)
      let recorder = ObservationRecorder<Int>()
      let subscription = try OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
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

      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO notes VALUES (1)")
      }
      #expect(fetchCount.withLock { $0 } == 1)

      try driver.writeBlocking { transaction in
        try transaction.execute("UPDATE settings SET useNotes = 1")
      }
      #expect(recorder.changes.map(\.value) == [0, 1])

      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO items VALUES (1)")
      }
      #expect(fetchCount.withLock { $0 } == 2)

      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO notes VALUES (2)")
      }
      #expect(fetchCount.withLock { $0 } == 3)
      #expect(recorder.changes.map(\.value) == [0, 1, 2])
      _ = subscription
    }

    @Test
    func automaticRegionIncludesManuallyPublishedReads() throws {
      let driver = try SQLiteQueue(path: .memory)
      let fetchCount = Lock(0)
      let region = OrbitDatabaseRegion(table: "raw_items")
      let subscription = try OrbitValueObservation<Int>
        .tracking { transaction in
          fetchCount.withLock { $0 += 1 }
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
      #expect(fetchCount.withLock { $0 } == 1)

      try driver.writeBlocking { transaction in
        transaction.notifyChanges(in: region)
      }
      #expect(fetchCount.withLock { $0 } == 2)
      _ = subscription
    }

    @Test
    func rollbackClearsItsPublishedRegion() throws {
      struct Abort: Error {}

      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute(
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY);
          CREATE TABLE notes (id INTEGER PRIMARY KEY);
          """
        )
      }
      let fetchCount = Lock(0)
      let subscription = try OrbitValueObservation<Int>
        .tracking(region: OrbitDatabaseRegion(table: "items")) { transaction in
          fetchCount.withLock { $0 += 1 }
          return try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
        }
        .subscribe(
          to: driver,
          scheduling: .immediate,
          onError: { _ in },
          onChange: { _ in }
        )

      #expect(throws: Abort.self) {
        try driver.writeBlocking { transaction in
          try transaction.execute("INSERT INTO items VALUES (1)")
          throw Abort()
        }
      }
      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO notes VALUES (1)")
      }

      #expect(fetchCount.withLock { $0 } == 1)
      _ = subscription
    }

    @Test
    func trackingAllDerivesItsRegionFromTypedSQL() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute(
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL, ignored TEXT);
          CREATE TABLE notes (id INTEGER PRIMARY KEY);
          INSERT INTO items VALUES (1, 'Before', NULL);
          """
        )
      }
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

      try driver.writeBlocking { transaction in
        try transaction.execute("UPDATE items SET title = 'After' WHERE id = 1")
      }
      #expect(recorder.changes.map(\.value) == [["Before"], ["After"]])
      #expect(recorder.errors.isEmpty)
      _ = subscription
    }

    @Test
    func trackingAllAndOneInferTypedQueryOutputs() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute(
          """
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
      }

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
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT)")
      }
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
      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO items VALUES (1, 'One')")
      }
      #expect(recorder.changes.map(\.value) == [nil, "One"])
      _ = subscription
    }

    @Test
    func emptyQueryRegionDoesNotRefetch() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
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

      try driver.writeBlocking { transaction in
        try transaction.execute("INSERT INTO items VALUES (1)")
      }
      #expect(recorder.changes.map(\.value) == [1])
      _ = subscription
    }

    @Test
    func queryObservationConservativelyRefetchesAfterExternalCommit() async throws {
      let driver = try await itemsDatabase()
      let network = InMemoryIPCTransport.Network()
      let receivingTransport = InMemoryIPCTransport(network: network)
      let sendingTransport = InMemoryIPCTransport(network: network)
      let identifier = OrbitDatabaseIdentifier(rawValue: "query-region-external-observation")
      let database = OrbitDatabase(
        writer: driver,
        id: identifier,
        transport: receivingTransport
      )
      let changes =
        OrbitValueObservation
        .trackingAll(#sql("SELECT id FROM items", as: Int.self))
        .changes(in: database)
      var iterator = changes.makeAsyncIterator()

      #expect(try await iterator.next()?.source == .initial)
      try await sendingTransport.send(
        .transactionDidCommit(.init(databaseIdentifier: identifier, region: .fullDatabase))
      )
      #expect(try await iterator.next()?.source == .transaction(.external))
    }

    @Test
    func writableTypedSQLIsRejectedBeforeItExecutes() throws {
      let driver = try SQLiteQueue(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute(
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
        try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self))
      }
      #expect(count == 1)
      #expect(recorder.changes.isEmpty)
      #expect(recorder.errors.count == 1)
      _ = subscription
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

  private func itemsDatabase() async throws -> SQLiteQueue {
    let driver = try SQLiteQueue(path: .memory)
    try await driver.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    return driver
  }

  private func itemCountObservation() -> OrbitValueObservation<Int> {
    OrbitValueObservation.tracking { transaction in
      try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
    }
  }

  private final class ObservationRecorder<Value: Sendable>: Sendable {
    private struct State: Sendable {
      var changes = [OrbitValueObservationChange<Value>]()
      var errors = [String]()
    }

    private let state = Lock(State())

    var changes: [OrbitValueObservationChange<Value>] { state.withLock { $0.changes } }
    var errors: [String] { state.withLock { $0.errors } }

    func record(change: OrbitValueObservationChange<Value>) {
      state.withLock { $0.changes.append(change) }
    }

    func record(error: any Error) {
      state.withLock { $0.errors.append(String(describing: error)) }
    }

    func waitForChangeCount(_ count: Int) async throws {
      try await waitUntil(timeout: .seconds(5)) { self.changes.count >= count }
    }
  }

  private final class FetchGate: Sendable {
    private let state = Lock((entered: false, isOpen: false))

    func hold() {
      state.withLock { $0.entered = true }
      while !state.withLock({ $0.isOpen }) {}
    }

    func waitUntilEntered() async throws {
      try await waitUntil(timeout: .seconds(5)) { self.state.withLock { $0.entered } }
    }

    func open() {
      state.withLock { $0.isOpen = true }
    }
  }

  private final class RecordingRefetchPolicy: OrbitValueObservationRefetchPolicy, Sendable {
    private let recordedSnapshots = Lock<[OrbitValueObservationRefetchSnapshot]>([])

    var snapshots: [OrbitValueObservationRefetchSnapshot] {
      recordedSnapshots.withLock { $0 }
    }

    func refetch(using context: consuming OrbitValueObservationRefetchContext) async {
      var context = context
      recordedSnapshots.withLock { $0.append(context.snapshot()) }
      await context.fetch(publishing: .force)
    }

    func waitForSnapshot() async throws {
      try await waitUntil(timeout: .seconds(5)) { !self.snapshots.isEmpty }
    }
  }

  private final class PostCommitObservableDatabase: OrbitObservableDatabase {
    let defaultIdentifier: OrbitDatabaseIdentifier

    private let base: SQLiteQueue
    private let observers = OrbitDatabaseTransactionObservers()

    init(_ base: SQLiteQueue) {
      self.base = base
      self.defaultIdentifier = base.defaultIdentifier
    }

    func read<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) async throws -> Result {
      try await base.read(body)
    }

    func write<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) async throws -> Result {
      let (result, region) = try await base.write { transaction in
        try transaction.recordingDatabaseRegion(body)
      }
      announceCommit(region: region)
      return result
    }

    func readBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteReadTransaction) throws -> Result
    ) throws -> Result {
      try base.readBlocking(body)
    }

    func writeBlocking<Result: Sendable>(
      _ body: sending (borrowing SQLiteWriteTransaction) throws -> Result
    ) throws -> Result {
      let (result, region) = try base.writeBlocking { transaction in
        try transaction.recordingDatabaseRegion(body)
      }
      announceCommit(region: region)
      return result
    }

    func subscribe(
      transactionObserver: any OrbitDatabaseTransactionObserver
    ) throws -> OrbitSubscription {
      observers.subscribe(transactionObserver)
    }

    func announceCommit(
      region: OrbitDatabaseRegion,
      origin: OrbitDatabaseTransactionOrigin = .local,
      activeWriterBarrier: SQLitePoolWriterBarrier? = nil
    ) {
      observers.didChange(in: region)
      observers.didCommit(
        origin: origin,
        region: region,
        activeWriterBarrier: activeWriterBarrier
      )
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
