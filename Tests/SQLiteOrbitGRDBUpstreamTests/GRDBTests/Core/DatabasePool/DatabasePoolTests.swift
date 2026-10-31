// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/DatabasePool/DatabasePoolTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
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

class DatabasePoolTests: GRDBTestCase {

    
    func testDatabasePoolCreatesWalShm() throws {
        let dbPool = try makeDatabasePool(filename: "test")
        try withExtendedLifetime(dbPool) {
            let fm = FileManager()
            XCTAssertTrue(fm.fileExists(atPath: dbPool.path + "-wal"))
            XCTAssertTrue(fm.fileExists(atPath: dbPool.path + "-shm"))

#if SQLITE_ENABLE_SNAPSHOT && !SQLITE_DISABLE_SNAPSHOT
            // A non-empty wal file makes sure ValueObservation can use wal snapshots.
            // See <https://github.com/groue/GRDB.swift/issues/1383>
            let walURL = URL(fileURLWithPath: dbPool.path + "-wal")
            let walSize = try walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            XCTAssertGreaterThan(walSize, 0)
#endif
        }
    }
    
    func testDatabasePoolCreatesWalShmFromNonWalDatabase() throws {
        do {
            let dbQueue = try makeDatabaseQueue(filename: "test")
            try dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "CREATE TABLE t(a)")
            }
        }
        do {
            let dbPool = try makeDatabasePool(filename: "test")
            try withExtendedLifetime(dbPool) {
                let fm = FileManager()
                XCTAssertTrue(fm.fileExists(atPath: dbPool.path + "-wal"))
                XCTAssertTrue(fm.fileExists(atPath: dbPool.path + "-shm"))
                
#if SQLITE_ENABLE_SNAPSHOT && !SQLITE_DISABLE_SNAPSHOT
                // A non-empty wal file makes sure ValueObservation can use wal snapshots.
                // See <https://github.com/groue/GRDB.swift/issues/1383>
                let walURL = URL(fileURLWithPath: dbPool.path + "-wal")
                let walSize = try walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                XCTAssertGreaterThan(walSize, 0)
#endif
            }
        }
    }

    func testDatabasePoolCreatesWalShmFromTruncatedWalFile() throws {
        do {
            let dbPool = try makeDatabasePool(filename: "test")
            try dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "CREATE TABLE t(a)")
                try db.checkpoint(.truncate)
            }
        }
        do {
            let dbPool = try makeDatabasePool(filename: "test")
            try withExtendedLifetime(dbPool) {
                let fm = FileManager()
                XCTAssertTrue(fm.fileExists(atPath: dbPool.path + "-wal"))
                XCTAssertTrue(fm.fileExists(atPath: dbPool.path + "-shm"))
                
#if SQLITE_ENABLE_SNAPSHOT && !SQLITE_DISABLE_SNAPSHOT
                // A non-empty wal file makes sure ValueObservation can use wal snapshots.
                // See <https://github.com/groue/GRDB.swift/issues/1383>
                let walURL = URL(fileURLWithPath: dbPool.path + "-wal")
                let walSize = try walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                XCTAssertGreaterThan(walSize, 0)
#endif
            }
        }
    }

    func testDatabasePoolCreatesWalShmFromIssue1383() throws {
        let url = testBundle.url(forResource: "Issue1383", withExtension: "sqlite")!
        // Delete files created by previous test runs
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("Issue1383.sqlite-wal"))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("Issue1383.sqlite-shm"))

        let dbPool = try DatabasePool(path: url.path)
        try withExtendedLifetime(dbPool) {
            let fm = FileManager()
            XCTAssertTrue(fm.fileExists(atPath: dbPool.path + "-wal"))
            XCTAssertTrue(fm.fileExists(atPath: dbPool.path + "-shm"))
            
#if SQLITE_ENABLE_SNAPSHOT && !SQLITE_DISABLE_SNAPSHOT
            // A non-empty wal file makes sure ValueObservation can use wal snapshots.
            // See <https://github.com/groue/GRDB.swift/issues/1383>
            let walURL = URL(fileURLWithPath: dbPool.path + "-wal")
            let walSize = try walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            XCTAssertGreaterThan(walSize, 0)
#endif
        }
    }
    
    func testCanReadFromNewInstance() throws {
        let dbPool = try makeDatabasePool()
        try dbPool.read { _ in }
    }
    
    func testCanReadFromTruncatedWalFile() throws {
        do {
            let dbPool = try makeDatabasePool(filename: "test")
            try dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "CREATE TABLE t(a)")
                try db.checkpoint(.truncate)
            }
        }
        do {
            let dbPool = try makeDatabasePool(filename: "test")
            let count = try dbPool.read(Table("t").fetchCount)
            XCTAssertEqual(count, 0)
        }
    }
    
    func testPersistentWALModeEnabled() throws {
        let path: String
        do {
            dbConfiguration.prepareDatabase { db in
                var flag: CInt = 1
                let code = withUnsafeMutablePointer(to: &flag) { flagP in
                    sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagP)
                }
                guard code == SQLITE_OK else {
                    throw DatabaseError(resultCode: ResultCode(rawValue: code))
                }
            }
            let dbPool = try makeDatabasePool()
            path = dbPool.path
        }
        let fm = FileManager()
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertTrue(fm.fileExists(atPath: path + "-wal"))
        XCTAssertTrue(fm.fileExists(atPath: path + "-shm"))
    }
    
    func testPersistentWALModeDisabled() throws {
        let path: String
        do {
            dbConfiguration.prepareDatabase { db in
                var flag: CInt = 0
                let code = withUnsafeMutablePointer(to: &flag) { flagP in
                    sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagP)
                }
                guard code == SQLITE_OK else {
                    throw DatabaseError(resultCode: ResultCode(rawValue: code))
                }
            }
            let dbPool = try makeDatabasePool()
            path = dbPool.path
        }
        let fm = FileManager()
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertFalse(fm.fileExists(atPath: path + "-wal"))
        XCTAssertFalse(fm.fileExists(atPath: path + "-shm"))
    }
    
    // Regression test
    func testIssue931() throws {
        dbConfiguration.prepareDatabase { db in
            var flag: CInt = 0
            let code = withUnsafeMutablePointer(to: &flag) { flagP in
                sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagP)
            }
            guard code == SQLITE_OK else {
                throw DatabaseError(resultCode: ResultCode(rawValue: code))
            }
        }
        let dbQueue = try makeDatabaseQueue()
        
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: { _ in })
        migrator.eraseDatabaseOnSchemaChange = true
        try migrator.migrate(dbQueue)
        
        // Trigger #931: the migrator creates a temporary database and
        // calls `sqlite3_file_control` as part of the preparation function.
        try migrator.migrate(dbQueue)
    }
    
    func testNumberOfThreads_asyncUnsafeRead() throws {
#if SWIFT_PACKAGE
        // Can't access getThreadsCount() C function
        throw XCTSkip("Thread count is not available")
#else
        if getThreadsCount() < 0 {
            throw XCTSkip("Thread count is not available")
        }
        
        let pool = try makeDatabasePool()
        
        // Keep this number big, so that we have a good chance to detect
        // thread explosion.
        let numberOfConcurrentReads = 10000
        
        // Wait for all concurrent reads to end
        let group = DispatchGroup()
        
        // The maximum number of threads we could witness
        let maxThreadCountMutex: Mutex<CInt> = Mutex(0)
        for _ in (0..<numberOfConcurrentReads) {
            group.enter()
            pool.asyncUnsafeRead { result in
                if case let .failure(error) = result {
                    XCTFail("Unexpected error \(error)")
                }
                
                let threadsCount = getThreadsCount()
                maxThreadCountMutex.withLock {
                    $0 = max($0, threadsCount)
                }
                
                group.leave()
            }
        }
        group.wait()
        XCTAssert(maxThreadCountMutex.load() < 50)
#endif
    }
    
    func testNumberOfThreads_asyncRead() throws {
#if SWIFT_PACKAGE
        // Can't access getThreadsCount() C function
        throw XCTSkip("Thread count is not available")
#else
        if getThreadsCount() < 0 {
            throw XCTSkip("Thread count is not available")
        }
        
        let pool = try makeDatabasePool()
        
        // Keep this number big, so that we have a good chance to detect
        // thread explosion.
        let numberOfConcurrentReads = 10000
        
        // Wait for all concurrent reads to end
        let group = DispatchGroup()
        
        // The maximum number of threads we could witness
        let maxThreadCountMutex: Mutex<CInt> = Mutex(0)
        for _ in (0..<numberOfConcurrentReads) {
            group.enter()
            pool.asyncRead { result in
                if case let .failure(error) = result {
                    XCTFail("Unexpected error \(error)")
                }
                
                let threadsCount = getThreadsCount()
                maxThreadCountMutex.withLock {
                    $0 = max($0, threadsCount)
                }
                
                group.leave()
            }
        }
        group.wait()
        XCTAssert(maxThreadCountMutex.load() < 50)
#endif
    }
    
    // MARK: - Closing
    

    

    

    

    

    

}
