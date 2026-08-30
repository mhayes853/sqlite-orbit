import Foundation
import GRDB
import SQLiteCross
import Testing

@Test
func transactionCommitRoundTripsThroughJSON() throws {
  let commit = TransactionCommit(
    database: DatabaseIdentifier(rawValue: "example-database"),
    source: ProcessIdentifier(rawValue: "example-process")
  )

  let data = try JSONEncoder().encode(commit)
  let decoded = try JSONDecoder().decode(TransactionCommit.self, from: data)

  #expect(decoded == commit)
}

@Test
func externalCommitNotifiesGRDBObservers() async throws {
  let writer = try DatabaseQueue()
  try await writer.write { database in
    try database.execute(sql: "CREATE TABLE item (id INTEGER PRIMARY KEY)")
  }

  let observer = RecordingTransactionObserver()
  writer.add(transactionObserver: observer, extent: .observerLifetime)

  let database = TestDatabase(
    identifier: DatabaseIdentifier(rawValue: "test-database"),
    writer: writer
  )
  try await database.notifyChangesFromExternalCommit()

  #expect(observer.didObserveChange)
  #expect(observer.didCommit)
}

private struct TestDatabase: CrossProcessDatabase {
  let identifier: DatabaseIdentifier
  let writer: any DatabaseWriter
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
