// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabaseQueue/DatabaseQueueTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import Dispatch
import SQLiteOrbitGRDB

class DatabaseQueueTests: GRDBTestCase {

    
    func testInvalidFileFormat() throws {
        do {
            let url = testBundle.url(forResource: "Betty", withExtension: "jpeg")!
            guard (try? Data(contentsOf: url)) != nil else {
                XCTFail("Missing file")
                return
            }
            _ = try DatabaseQueue(path: url.path)
            XCTFail("Expected error")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_NOTADB)
            XCTAssert([
                "file is encrypted or is not a database",
                "file is not a database"].contains(error.message!))
        }
    }
    

    

    

    

    

    

    

    


    func testQoS() throws {
#if !canImport(Darwin)
        throw XCTSkip("__dispatch_get_global_queue not available on non-Darwin platforms")
#else
        func test(qos: DispatchQoS) throws {
            // https://forums.swift.org/t/what-is-the-default-target-queue-for-a-serial-queue/18094/5
            //
            // > [...] the default target queue [for a serial queue] is the
            // > [default] overcommit [global concurrent] queue.
            //
            // We want this default target queue in order to test database QoS
            // with dispatchPrecondition(condition:).
            //
            // > [...] You can get a reference to the overcommit queue by
            // > dropping down to the C function dispatch_get_global_queue
            // > (available in Swift with a __ prefix) and passing the private
            // > value of DISPATCH_QUEUE_OVERCOMMIT.
            // >
            // > [...] Of course you should not do this in production code,
            // > because DISPATCH_QUEUE_OVERCOMMIT is not a public API. I don't
            // > know of a way to get a reference to the overcommit queue using
            // > only public APIs.
            let DISPATCH_QUEUE_OVERCOMMIT: UInt = 2
            let targetQueue = __dispatch_get_global_queue(
                Int(qos.qosClass.rawValue.rawValue),
                DISPATCH_QUEUE_OVERCOMMIT)
            
            dbConfiguration.qos = qos
            let dbQueue = try makeDatabaseQueue()
            try dbQueue.write { _ in
                dispatchPrecondition(condition: .onQueue(targetQueue))
            }
            try dbQueue.read { _ in
                dispatchPrecondition(condition: .onQueue(targetQueue))
            }
        }
        
        try test(qos: .background)
        try test(qos: .userInitiated)
#endif
    }
    
    // MARK: - SQLITE_BUSY prevention
    

    

    
    // See <https://github.com/groue/GRDB.swift/issues/1483>
    func test_busy_timeout_and_IMMEDIATE_transactions_do_prevent_SQLITE_BUSY() throws {
        var configuration = dbConfiguration!
        // Test fails when this line is commented
        configuration.busyMode = .timeout(10)
        
        let dbQueue = try makeDatabaseQueue(filename: "test")
        try dbQueue.inDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = wal")
            try db.execute(sql: "CREATE TABLE test(a)")
        }
        
        let parallelWritesCount = 50
        DispatchQueue.concurrentPerform(iterations: parallelWritesCount) { [configuration] index in
            let dbQueue = try! makeDatabaseQueue(filename: "test", configuration: configuration)
            try! dbQueue.write { db in
                _ = try Table("test").fetchCount(db)
                try db.execute(sql: "INSERT INTO test VALUES (1)")
            }
        }
        
        let count = try dbQueue.read(Table("test").fetchCount)
        XCTAssertEqual(count, parallelWritesCount)
    }

    // MARK: - Closing
    

    

    

    

    

}
