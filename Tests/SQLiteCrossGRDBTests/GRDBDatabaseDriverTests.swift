#if SQLiteCrossGRDB
  import Foundation
  import GRDB
  import SQLiteCross
  import SQLiteCrossGRDB
  import Testing

  @Test
  func localCommitReportsChangedTables() async throws {
    let writer = try DatabaseQueue()
    try await writer.write { database in
      try database.execute(sql: "CREATE TABLE item (id INTEGER PRIMARY KEY)")
    }
    let driver = GRDBDatabaseDriver(
      identifier: DatabaseIdentifier(rawValue: "test-database"),
      writer: writer
    )
    let recorder = RegionRecorder()
    let subscription = try driver.subscribeToLocalCommits { region in
      recorder.append(region)
    }

    try await writer.write { database in
      try database.execute(sql: "INSERT INTO item DEFAULT VALUES")
    }

    #expect(recorder.regions == [.tables(["item"])])
    subscription.cancel()
  }

  @Test
  func externalNotificationIsNotReportedAsLocalCommit() async throws {
    let writer = try DatabaseQueue()
    try await writer.write { database in
      try database.execute(sql: "CREATE TABLE item (id INTEGER PRIMARY KEY)")
    }
    let driver = GRDBDatabaseDriver(
      identifier: DatabaseIdentifier(rawValue: "test-database"),
      writer: writer
    )
    let recorder = RegionRecorder()
    let subscription = try driver.subscribeToLocalCommits { region in
      recorder.append(region)
    }
    let observer = RecordingTransactionObserver()
    writer.add(transactionObserver: observer, extent: .observerLifetime)

    try await driver.notifyChangesFromExternalCommit(in: .tables(["item"]))

    #expect(recorder.regions.isEmpty)
    #expect(observer.didObserveChange)
    #expect(observer.didCommit)
    subscription.cancel()
  }

  private final class RegionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRegions: [DatabaseChangeRegion] = []

    var regions: [DatabaseChangeRegion] {
      lock.withLock { recordedRegions }
    }

    func append(_ region: DatabaseChangeRegion) {
      lock.withLock {
        recordedRegions.append(region)
      }
    }
  }

  private final class RecordingTransactionObserver: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _didObserveChange = false
    private var _didCommit = false

    var didObserveChange: Bool {
      lock.withLock { _didObserveChange }
    }

    var didCommit: Bool {
      lock.withLock { _didCommit }
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
      true
    }

    func databaseDidChange() {
      lock.withLock {
        _didObserveChange = true
      }
    }

    func databaseDidChange(with event: DatabaseEvent) {}

    func databaseWillCommit() throws {}

    func databaseDidCommit(_ database: Database) {
      lock.withLock {
        _didCommit = true
      }
    }

    func databaseDidRollback(_ database: Database) {}
  }
#endif
