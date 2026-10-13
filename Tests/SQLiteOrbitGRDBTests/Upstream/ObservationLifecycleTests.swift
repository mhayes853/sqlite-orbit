// Shared application fixture, run against both the overlay and GRDB 7.11.1.
import Dispatch
import Foundation
import XCTest
import SQLiteOrbitGRDB

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
  func testSubscriptionsHaveIndependentLifecycles() throws {
    let database = try makeDatabaseQueue()
    let starts = ObservationCounter()
    let fetches = ObservationCounter()
    let cancellations = ObservationCounter()
    let observation = ValueObservation.tracking { db in
      fetches.increment()
      return try Int.fetchOne(db, sql: "SELECT 1")!
    }.handleEvents(
      willStart: { starts.increment() },
      didCancel: { cancellations.increment() }
    )
    let queue = DispatchQueue(label: "observation-lifecycle")
    let firstValue = expectation(description: "first subscription")
    let secondValue = expectation(description: "second subscription")
    let first = observation.start(
      in: database, scheduling: .async(onQueue: queue),
      onError: { XCTFail(String(describing: $0)) },
      onChange: { _ in firstValue.fulfill() }
    )
    let second = observation.start(
      in: database, scheduling: .async(onQueue: queue),
      onError: { XCTFail(String(describing: $0)) },
      onChange: { _ in secondValue.fulfill() }
    )
    defer { first.cancel(); second.cancel() }
    wait(for: [firstValue, secondValue], timeout: 5)
    XCTAssertEqual(starts.value, 2)
    XCTAssertEqual(fetches.value, 2)
    first.cancel()
    XCTAssertEqual(cancellations.value, 1)
    second.cancel()
    XCTAssertEqual(cancellations.value, 2)
  }
}
