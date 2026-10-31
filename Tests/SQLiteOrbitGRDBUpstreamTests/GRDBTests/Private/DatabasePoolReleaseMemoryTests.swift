// Generated from GRDB 7.11.1 Tests/GRDBTests/Private/DatabasePoolReleaseMemoryTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest/ and run `sync`.
#if !Turso
// Import C SQLite functions
#if GRDBCIPHER // CocoaPods (SQLCipher subspec)
import SQLCipher
#elseif GRDBFRAMEWORK // GRDB.xcodeproj or CocoaPods (standard subspec)
import CSQLite3
#elseif GRDBCUSTOMSQLITE // GRDBCustom Framework
#elseif SQLCipher
import SQLCipher
#else // Default SPM trait must be the default. It impossible to detect from Xcode.
import CSQLite3
#endif

import XCTest
import SQLiteOrbitGRDB

class DatabasePoolReleaseMemoryTests: GRDBTestCase {
    

    
#if os(iOS)
    func testDatabasePoolReleasesMemoryOnPressureEvent() throws {
        // Create a database pool, and expect a reader connection to be closed
        let expectation = self.expectation(description: "Reader connection closed")
        
        var configuration = Configuration()
        configuration.onConnectionWillClose { conn in
            if sqlite3_db_readonly(conn, nil) != 0 {
                expectation.fulfill()
            }
        }
        let dbPool = try makeDatabasePool(configuration: configuration)
        
        // Precondition: there is one reader.
        try dbPool.read { _ in }
        
        // Simulate memory warning.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil)
        
        // Postcondition: reader connection was closed
        withExtendedLifetime(dbPool) { _ in
            waitForExpectations(timeout: 0.5)
        }
    }
    
    func testDatabasePoolDoesNotReleaseMemoryOnPressureEventIfDisabled() throws {
        // Create a database pool, and do not expect any reader connection to be closed
        let expectation = self.expectation(description: "Reader connection closed")
        expectation.isInverted = true
        
        var configuration = Configuration()
        configuration.automaticMemoryManagement = false
        configuration.onConnectionWillClose { conn in
            if sqlite3_db_readonly(conn, nil) != 0 {
                expectation.fulfill()
            }
        }
        let dbPool = try makeDatabasePool(configuration: configuration)
        
        // Precondition: there is one reader.
        try dbPool.read { _ in }
        
        // Simulate memory warning.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil)
        
        // Postcondition: no reader connection was closed
        withExtendedLifetime(dbPool) { _ in
            waitForExpectations(timeout: 0.5)
        }
    }
    
    // Regression test for <https://github.com/groue/GRDB.swift/pull/1253#issuecomment-1177166630>
    func testDatabasePoolDoesNotPreventConcurrentReadsOnPressureEvent() throws {
        let dbPool = try makeDatabasePool()
        
        // Start a read that blocks
        let semaphore = DispatchSemaphore(value: 0)
        dbPool.asyncRead { _ in
            semaphore.wait()
        }
        
        // Simulate memory warning.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil)
        
        // Make sure we can read
        try dbPool.read { _ in }
        
        // Cleanup
        semaphore.signal()
    }
    
#endif
    

    

    

    

    
    func testStatementDoNotRetainDatabaseConnection() throws {
        // Block 1                  Block 2
        //                          create statement INSERT
        //                          >
        let s1 = DispatchSemaphore(value: 0)
        // dbPool = nil
        // >
        let s2 = DispatchSemaphore(value: 0)
        //                          dbPool is nil
        
        let (block1, block2) = { () -> (() -> (), () -> ()) in
            var dbPool: DatabasePool? = try! self.makeDatabasePool()
            let block1 = { () in
                _ = s1.wait(timeout: .distantFuture)
                dbPool = nil
                s2.signal()
            }
            let block2 = { [weak dbPool] () in
                var statement: Statement? = nil
                do {
                    if let dbPool {
                        do {
                            try dbPool.write { db in
                                statement = try db.makeStatement(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
                                s1.signal()
                            }
                        } catch {
                            XCTFail("error: \(error)")
                        }
                    } else {
                        XCTFail("expect non nil dbPool")
                    }
                }
                _ = s2.wait(timeout: .distantFuture)
                XCTAssertTrue(statement != nil)
                XCTAssertTrue(dbPool == nil)
            }
            return (block1, block2)
        }()
        let blocks = [block1, block2]
        DispatchQueue.concurrentPerform(iterations: blocks.count) { index in
            blocks[index]()
        }
    }
}
#endif  // !Turso
