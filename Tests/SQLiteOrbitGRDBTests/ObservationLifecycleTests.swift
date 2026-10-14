// Orbit observations share runtimes by definition and database, unlike GRDB defaults.
import Dispatch
import Foundation
import SQLiteOrbitGRDB
import XCTest

private final class ObservationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

class ObservationLifecycleTests: GRDBTestCase {
  func testSubscriptionsShareFetchesAndLifecycleWithSeparateScheduling() throws {
    let database = try makeDatabaseQueue()
    try database.write { db in
      try db.execute(sql: "CREATE TABLE t(n); INSERT INTO t VALUES (1)")
    }
    let starts = ObservationCounter()
    let fetches = ObservationCounter()
    let reductions = ObservationCounter()
    let cancellations = ObservationCounter()
    let observation =
      ValueObservation.tracking { db in
        fetches.increment()
        return try Int.fetchOne(db, sql: "SELECT n FROM t")!
      }
      .map { value in
        reductions.increment()
        return value
      }
      .handleEvents(
        willStart: { starts.increment() },
        didCancel: { cancellations.increment() }
      )
    let firstQueue = DispatchQueue(label: "observation-first")
    let secondQueue = DispatchQueue(label: "observation-second")
    let firstValue = expectation(description: "first subscription")
    firstValue.assertForOverFulfill = true
    let secondValue = expectation(description: "replayed value")
    let update = expectation(description: "remaining subscription update")
    let first = observation.start(
      in: database,
      scheduling: .async(onQueue: firstQueue),
      onError: { XCTFail(String(describing: $0)) },
      onChange: { value in
        dispatchPrecondition(condition: .onQueue(firstQueue))
        XCTAssertEqual(value, 1)
        firstValue.fulfill()
      }
    )
    defer { first.cancel() }
    wait(for: [firstValue], timeout: 5)
    let second = observation.start(
      in: database,
      scheduling: .async(onQueue: secondQueue),
      onError: { XCTFail(String(describing: $0)) },
      onChange: { value in
        dispatchPrecondition(condition: .onQueue(secondQueue))
        switch value {
        case 1: secondValue.fulfill()
        case 2: update.fulfill()
        default: XCTFail("unexpected value: \(value)")
        }
      }
    )
    defer { second.cancel() }
    wait(for: [secondValue], timeout: 5)
    XCTAssertEqual(starts.value, 1)
    XCTAssertEqual(fetches.value, 1)
    XCTAssertEqual(reductions.value, 1)
    first.cancel()
    XCTAssertEqual(cancellations.value, 0)
    try database.write { try $0.execute(sql: "UPDATE t SET n=2") }
    wait(for: [update], timeout: 5)
    XCTAssertEqual(fetches.value, 2)
    XCTAssertEqual(reductions.value, 2)
    second.cancel()
    XCTAssertEqual(cancellations.value, 1)

    let restartedValue = expectation(description: "restarted runtime")
    let restarted = observation.start(
      in: database,
      scheduling: .async(onQueue: firstQueue),
      onError: { XCTFail(String(describing: $0)) },
      onChange: { value in
        XCTAssertEqual(value, 2)
        restartedValue.fulfill()
      }
    )
    defer { restarted.cancel() }
    wait(for: [restartedValue], timeout: 5)
    XCTAssertEqual(starts.value, 2)
    XCTAssertEqual(fetches.value, 3)
    restarted.cancel()
    XCTAssertEqual(cancellations.value, 2)
  }
}
