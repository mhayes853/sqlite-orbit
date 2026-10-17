// Selected test bodies from GRDB 7.11.1; see LICENSE and provenance.md.
import Foundation
import Dispatch
import XCTest
import SQLiteOrbitGRDB

// XCTest executes these synchronous bodies on the main thread. The unchecked conformance
// permits the original waitForExpectations calls under Swift 6 without actor-isolated discovery.
class DatabaseWriterTests: GRDBTestCase, @unchecked Sendable {
    func testAsyncWriteWithoutTransactionSuccess() throws {
        func test(_ dbWriter: some DatabaseWriter) throws {
            let expectation = self.expectation(description: "updates")
            let semaphore = DispatchSemaphore(value: 0)
            dbWriter.asyncWriteWithoutTransaction { db in
                // Make sure this block executes asynchronously
                semaphore.wait()
                do {
                    try db.execute(sql: "CREATE TABLE testAsyncWriteWithoutTransaction (a)")
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
                expectation.fulfill()
            }
            semaphore.signal()

            waitForExpectations(timeout: 2, handler: nil)
            let tableExists = try dbWriter.read { try $0.tableExists("testAsyncWriteWithoutTransaction") }
            XCTAssertTrue(tableExists)
        }

        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    func testAsyncWriteWithoutTransactionError() throws {
        func test(_ dbWriter: some DatabaseWriter) throws {
            let expectation = self.expectation(description: "updates")
            let semaphore = DispatchSemaphore(value: 0)
            dbWriter.asyncWriteWithoutTransaction { db in
                // Make sure this block executes asynchronously
                semaphore.wait()
                do {
                    try db.execute(sql: "This is not SQL")
                    XCTFail("Expected error")
                } catch let error as DatabaseError {
                    XCTAssertEqual(error.sql, "This is not SQL")
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
                expectation.fulfill()
            }
            semaphore.signal()
            waitForExpectations(timeout: 2, handler: nil)
        }

        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    func testAsyncWriteSuccess() throws {
        func test(_ dbWriter: some DatabaseWriter) throws {
            let expectation = self.expectation(description: "updates")
            let semaphore = DispatchSemaphore(value: 0)
            dbWriter.asyncWrite({ db in
                // Make sure this block executes asynchronously
                semaphore.wait()
                try db.execute(sql: "CREATE TABLE testAsyncWrite (a)")
            }, completion: { db, result in
                XCTAssertFalse(db.isInsideTransaction)
                switch result {
                case .success:
                    break
                case let .failure(error):
                    XCTFail("Unexpected error: \(error)")
                }
                expectation.fulfill()
            })
            semaphore.signal()

            waitForExpectations(timeout: 2, handler: nil)
            let tableExists = try dbWriter.read { try $0.tableExists("testAsyncWrite") }
            XCTAssertTrue(tableExists)
        }

        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    func testAsyncWriteError() throws {
        func test(_ dbWriter: some DatabaseWriter) throws {
            let expectation = self.expectation(description: "updates")
            let semaphore = DispatchSemaphore(value: 0)
            dbWriter.asyncWrite({ db in
                // Make sure this block executes asynchronously
                semaphore.wait()
                try db.execute(sql: "This is not SQL")
            }, completion: { db, result in
                XCTAssertFalse(db.isInsideTransaction)
                switch result {
                case .success:
                    XCTFail("Expected error")
                case let .failure(error):
                    if let error = error as? DatabaseError {
                        XCTAssertEqual(error.sql, "This is not SQL")
                    } else {
                        XCTFail("Unexpected error: \(error)")
                    }
                }
                expectation.fulfill()
            })
            semaphore.signal()
            waitForExpectations(timeout: 2, handler: nil)
        }

        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
}
