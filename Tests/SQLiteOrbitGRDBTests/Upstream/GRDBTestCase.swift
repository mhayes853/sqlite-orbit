import Foundation
import SQLiteOrbitGRDB
import XCTest

class GRDBTestCase: XCTestCase {
  func setup(_ dbWriter: some DatabaseWriter) throws {}
  func makeDatabasePool() throws -> DatabasePool {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    addTeardownBlock {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    let pool = try DatabasePool(path: path)
    try setup(pool)
    return pool
  }
  func makeDatabaseQueue() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try setup(queue)
    return queue
  }
}
