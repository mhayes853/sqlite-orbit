#if SystemSQLite
  import Foundation
  import StructuredQueriesSQLite
  import Synchronization
  import Testing

  @testable import SQLiteCross

  @Suite
  struct DatabaseTransactionObservationTests {
    @Test
    func localDriverReportsCommitLifecycleAndFinalTransactionState() async throws {
      let driver = try SQLiteQueueDriver(path: .memory)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(observer.events == [.willCommit(1), .didCommit(.local)])
      _ = subscription
    }

    @Test
    func bodyFailureReportsRollbackWithoutWillCommit() async throws {
      struct Abort: Error {}

      let driver = try SQLiteQueueDriver(path: .memory)
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      await #expect(throws: Abort.self) {
        try await driver.write { transaction in
          try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
          throw Abort()
        }
      }

      #expect(observer.events == [.didRollback])
      _ = subscription
    }

    @Test
    func willCommitFailureAbortsTheWriteAndReportsRollback() async throws {
      struct Abort: Error {}

      let driver = try SQLiteQueueDriver(path: .memory)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = FailingTransactionObserver(error: Abort())
      let subscription = try driver.subscribe(transactionObserver: observer)

      await #expect(throws: Abort.self) {
        try await driver.write { transaction in
          try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
        }
      }

      #expect(observer.didRollback)
      let count = try await driver.read { transaction in
        try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self))
      }
      #expect(count == 0)
      _ = subscription
    }

    @Test
    func cancellingSubscriptionStopsTransactionEvents() async throws {
      let driver = try SQLiteQueueDriver(path: .memory)
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)
      subscription.cancel()

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(observer.events.isEmpty)
    }

    @Test
    func blockingWritesUseTheSameObserverLifecycle() throws {
      let driver = try SQLiteQueueDriver(path: .memory)
      try driver.writeBlocking { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try driver.writeBlocking { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(observer.events == [.willCommit(1), .didCommit(.local)])
      _ = subscription
    }

    @Test
    func poolWritesUseTheSameObserverLifecycle() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appending(component: UUID().uuidString, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }

      let driver = try SQLitePoolDriver(
        path: .file(directory.appending(component: "database.sqlite"))
      )
      try await driver.write { transaction in
        try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      }
      let observer = RecordingTransactionObserver()
      let subscription = try driver.subscribe(transactionObserver: observer)

      try await driver.write { transaction in
        try transaction.execute(#sql("INSERT INTO items (id) VALUES (1)", as: Void.self))
      }

      #expect(observer.events == [.willCommit(1), .didCommit(.local)])
      _ = subscription
    }
  }

  private enum RecordedTransactionEvent: Equatable, Sendable {
    case willCommit(Int)
    case didCommit(DatabaseTransactionOrigin)
    case didRollback
  }

  private final class RecordingTransactionObserver: DatabaseTransactionObserver, Sendable {
    private let recordedEvents = Mutex([RecordedTransactionEvent]())

    var events: [RecordedTransactionEvent] { recordedEvents.withLock { $0 } }

    func databaseWillCommit(
      _ transaction: borrowing SQLiteReadTransaction
    ) throws {
      let count = try transaction.fetchOne(#sql("SELECT COUNT(*) FROM items", as: Int.self)) ?? 0
      recordedEvents.withLock { $0.append(.willCommit(count)) }
    }

    func databaseDidCommit(_ commit: DatabaseCommit) {
      recordedEvents.withLock { $0.append(.didCommit(commit.origin)) }
    }

    func databaseDidRollback() {
      recordedEvents.withLock { $0.append(.didRollback) }
    }
  }

  private final class FailingTransactionObserver: DatabaseTransactionObserver, Sendable {
    private let error: any Error
    private let rollback = Mutex(false)

    var didRollback: Bool { rollback.withLock { $0 } }

    init(error: any Error) {
      self.error = error
    }

    func databaseWillCommit(
      _ transaction: borrowing SQLiteReadTransaction
    ) throws {
      throw error
    }

    func databaseDidRollback() {
      rollback.withLock { $0 = true }
    }
  }
#endif
