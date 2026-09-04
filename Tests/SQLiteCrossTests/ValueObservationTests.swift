#if SystemSQLite
  import Foundation
  import StructuredQueriesSQLite
  import Synchronization
  import Testing

  @testable import SQLiteCross

  @Suite
  struct ValueObservationTests {
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
      let driver = try SQLiteQueueDriver(path: .memory)
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
      let observation = ValueObservation<Int>
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
      let identifier = DatabaseIdentifier(rawValue: "external-observation")
      let database = InterprocessDatabase(
        writer: driver,
        id: identifier,
        transport: receivingTransport
      )
      let changes = itemCountObservation().changes(in: database)
      var iterator = changes.makeAsyncIterator()

      let initial = try #require(try await iterator.next())
      #expect(initial.source == .initial)

      try await sendingTransport.send(
        .transactionDidCommit(.init(databaseIdentifier: identifier))
      )
      let external = try #require(try await iterator.next())
      #expect(external.value == 0)
      #expect(external.source == .transaction(.external))
    }

    @Test
    func transactionFilterUsesTheCommitOriginBeforeFetching() async throws {
      let driver = try await itemsDatabase()
      let network = InMemoryIPCTransport.Network()
      let receivingTransport = InMemoryIPCTransport(network: network)
      let sendingTransport = InMemoryIPCTransport(network: network)
      let identifier = DatabaseIdentifier(rawValue: "filtered-observation")
      let database = InterprocessDatabase(
        writer: driver,
        id: identifier,
        transport: receivingTransport
      )
      let fetchCount = Mutex(0)
      let observation = ValueObservation<Int>
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
        .transactionDidCommit(.init(databaseIdentifier: identifier))
      )
      try await recorder.waitForChangeCount(2)

      #expect(fetchCount.withLock { $0 } == 2)
      #expect(recorder.changes.map(\.value) == [0, 1])
      #expect(recorder.changes.map(\.source) == [.initial, .transaction(.external)])
      _ = subscription
    }

    @Test
    func interprocessObservationSeesSiblingHandleWriteAsLocal() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appending(component: UUID().uuidString, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }

      let path = DatabasePath.file(directory.appending(component: "database.sqlite"))
      let identifier = DatabaseIdentifier(rawValue: "same-process-observation")
      let writingDatabase = InterprocessDatabase(
        writer: try SQLiteQueueDriver(path: path),
        id: identifier
      )
      try await writingDatabase.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observingDatabase = InterprocessDatabase(
        writer: try SQLiteQueueDriver(path: path),
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
    func cancellingValueSubscriptionStopsRefetching() async throws {
      let driver = try await itemsDatabase()
      let fetchCount = Mutex(0)
      let observation = ValueObservation<Int>
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
      let fetchCount = Mutex(0)
      let observation = ValueObservation<Int>
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
    func fetchErrorTerminatesTheAsyncSequence() async throws {
      let driver = try SQLiteQueueDriver(path: .memory)
      let values = itemCountObservation().values(in: driver)
      var iterator = values.makeAsyncIterator()

      await #expect(throws: (any Error).self) {
        _ = try await iterator.next()
      }
    }
  }

  private func itemsDatabase() async throws -> SQLiteQueueDriver {
    let driver = try SQLiteQueueDriver(path: .memory)
    try await driver.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    return driver
  }

  private func itemCountObservation() -> ValueObservation<Int> {
    ValueObservation.tracking { transaction in
      try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
    }
  }

  private struct ObservationTestTimeout: Error {}

  private final class ObservationRecorder<Value: Sendable>: Sendable {
    private struct State: Sendable {
      var changes = [ValueObservationChange<Value>]()
      var errors = [String]()
    }

    private let state = Mutex(State())

    var changes: [ValueObservationChange<Value>] { state.withLock { $0.changes } }
    var errors: [String] { state.withLock { $0.errors } }

    func record(change: ValueObservationChange<Value>) {
      state.withLock { $0.changes.append(change) }
    }

    func record(error: any Error) {
      state.withLock { $0.errors.append(String(describing: error)) }
    }

    func waitForChangeCount(_ count: Int) async throws {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(2))
      while changes.count < count {
        guard clock.now < deadline else { throw ObservationTestTimeout() }
        try await Task.sleep(for: .milliseconds(2))
      }
    }
  }
#endif
