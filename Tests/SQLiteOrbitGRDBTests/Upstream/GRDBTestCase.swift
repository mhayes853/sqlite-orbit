import XCTest
import SQLiteOrbitGRDB

class GRDBTestCase: XCTestCase {
  func setup(_ dbWriter: some DatabaseWriter) throws {}
  func makeDatabaseQueue() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try setup(queue)
    return queue
  }
}
