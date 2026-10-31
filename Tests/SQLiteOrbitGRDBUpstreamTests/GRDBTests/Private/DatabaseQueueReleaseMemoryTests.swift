// Generated from GRDB 7.11.1 Tests/GRDBTests/Private/DatabaseQueueReleaseMemoryTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest/ and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class DatabaseQueueReleaseMemoryTests: GRDBTestCase {
    

    

    
    func testStatementDoNotRetainDatabaseConnection() throws {
        // Block 1                  Block 2
        //                          create statement INSERT
        //                          >
        let s1 = DispatchSemaphore(value: 0)
        // dbQueue = nil
        // >
        let s2 = DispatchSemaphore(value: 0)
        //                          dbQueue is nil
        
        let (block1, block2) = { () -> (() -> (), () -> ()) in
            var dbQueue: DatabaseQueue? = try! self.makeDatabaseQueue()
            
            let block1 = { () in
                _ = s1.wait(timeout: .distantFuture)
                dbQueue = nil
                s2.signal()
            }
            let block2 = { [weak dbQueue] () in
                var statement: Statement? = nil
                do {
                    if let dbQueue {
                        do {
                            try dbQueue.write { db in
                                statement = try db.makeStatement(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
                                s1.signal()
                            }
                        } catch {
                            XCTFail("error: \(error)")
                        }
                    } else {
                        XCTFail("expect non nil dbQueue")
                    }
                }
                _ = s2.wait(timeout: .distantFuture)
                XCTAssertTrue(statement != nil)
                XCTAssertTrue(dbQueue == nil)
            }
            return (block1, block2)
        }()
        let blocks = [block1, block2]
        DispatchQueue.concurrentPerform(iterations: blocks.count) { index in
            blocks[index]()
        }
    }
}
