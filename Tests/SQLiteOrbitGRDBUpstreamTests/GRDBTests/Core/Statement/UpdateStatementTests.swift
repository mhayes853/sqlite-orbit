// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/Statement/UpdateStatementTests.swift by Tests/GRDBReference/grdb_upstream.py.
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

class UpdateStatementTests : GRDBTestCase {
    
    override func setup(_ dbWriter: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createPersons") { db in
            try db.execute(sql: """
                CREATE TABLE persons (
                    id INTEGER PRIMARY KEY,
                    creationDate TEXT,
                    name TEXT NOT NULL,
                    age INT)
                """)
        }
        try migrator.migrate(dbWriter)
    }
    

    
    func testStatementSQL() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try XCTAssertEqual(db.makeStatement(sql: "INSERT INTO persons (name, age) VALUES ('Arthur', ?)").sql, "INSERT INTO persons (name, age) VALUES ('Arthur', ?)")
            try XCTAssertEqual(db.makeStatement(sql: " INSERT INTO persons (name, age) VALUES ('Arthur', ?) ; ").sql, "INSERT INTO persons (name, age) VALUES ('Arthur', ?)")
            try XCTAssertEqual(db.makeStatement(sql: " INSERT INTO persons (name, age) VALUES ('Arthur', ?)\r\n").sql, "INSERT INTO persons (name, age) VALUES ('Arthur', ?)")
            try XCTAssertEqual(db.makeStatement(sql: " INSERT INTO persons (name, age) VALUES ('Arthur', ?)\t").sql, "INSERT INTO persons (name, age) VALUES ('Arthur', ?)")
            try XCTAssertEqual(db.makeStatement(sql: " INSERT INTO persons (name, age) VALUES ('Arthur', ?)\n").sql, "INSERT INTO persons (name, age) VALUES ('Arthur', ?)")
            try XCTAssertEqual(db.makeStatement(sql: " INSERT INTO persons (name, age) VALUES ('Arthur', ?)\u{000C}" /* \f */).sql, "INSERT INTO persons (name, age) VALUES ('Arthur', ?)")
        }
    }
    








    func testUpdateStatementAcceptsSelectQueries() throws {
        // This test makes sure we do not introduce any regression for
        // https://github.com/groue/GRDB.swift/issues/15
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "SELECT 1")
            let statement = try db.makeStatement(sql: "SELECT 1")
            try statement.execute()
        }
    }
    
    func testUpdateStatementAcceptsSelectQueriesAndConsumeAllRows() throws {
        let dbQueue = try makeDatabaseQueue()
        let indexMutex = Mutex(0)
        try dbQueue.inDatabase { db in
            db.add(function: DatabaseFunction("seq", argumentCount: 0, pure: false) { _ in
                indexMutex.increment()
            })
            try db.execute(sql: "SELECT seq() UNION ALL SELECT seq() UNION ALL SELECT seq()")
            let statement = try db.makeStatement(sql: "SELECT seq() UNION ALL SELECT seq() UNION ALL SELECT seq()")
            try statement.execute()
        }
        XCTAssertEqual(indexMutex.load(), 3 + 3)
    }

    func testExecuteNothing() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "")
            try db.execute(sql: " ")
            try db.execute(sql: ";")
            try db.execute(sql: ";;")
            try db.execute(sql: " \n;\t; ")
            try db.execute(sql: "\r\n")
            try db.execute(sql: "\u{000C}") // \f
            try db.execute(sql: "-- comment")
            try db.execute(sql: "-- comment\\n; -----ignored")
        }
    }
    
    func testExecuteMultipleStatement() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE wines (name TEXT, color INT); CREATE TABLE books (name TEXT, age INT)")
            XCTAssertTrue(try db.tableExists("wines"))
            XCTAssertTrue(try db.tableExists("books"))
        }
    }

    func testExecuteMultipleStatementWithTrailingWhiteSpace() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE wines (name TEXT, color INT); CREATE TABLE books (name TEXT, age INT)\n \t")
            XCTAssertTrue(try db.tableExists("wines"))
            XCTAssertTrue(try db.tableExists("books"))
        }
    }

    func testExecuteMultipleStatementWithTrailingSemicolonAndWhiteSpace() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE wines (name TEXT, color INT); CREATE TABLE books (name TEXT, age INT);\r\n \t")
            XCTAssertTrue(try db.tableExists("wines"))
            XCTAssertTrue(try db.tableExists("books"))
        }
    }

    func testExecuteMultipleStatementWithPlentyOfSemicolonsAndWhiteSpaceAndComments() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: """
                ;;
                CREATE TABLE wines ( -- create a table
                name TEXT, -- the name
                color INT);
                ;\t;
                -- create another table
                CREATE TABLE books (name TEXT, age INT); \
                 \t; ;
                """)
            XCTAssertTrue(try db.tableExists("wines"))
            XCTAssertTrue(try db.tableExists("books"))
        }
    }
    



    

    

    


    func testDatabaseErrorThrownByUpdateStatementContainSQL() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            do {
                _ = try db.makeStatement(sql: "UPDATE blah SET id = 12")
                XCTFail()
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message!, "no such table: blah")
                XCTAssertEqual(error.sql!, "UPDATE blah SET id = 12")
                XCTAssertEqual(error.description, "SQLite error 1: no such table: blah - while executing `UPDATE blah SET id = 12`")
            }
        }
    }
    
    func testMultipleValidStatementsError() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            do {
                _ = try db.makeStatement(sql: "UPDATE persons SET age = 1; UPDATE persons SET age = 2;")
                XCTFail("Expected error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_MISUSE)
                XCTAssertEqual(error.message!, """
                    Multiple statements found. To execute multiple statements, \
                    use Database.execute(sql:) or Database.allStatements(sql:) instead.
                    """)
                XCTAssertEqual(error.sql!, "UPDATE persons SET age = 1; UPDATE persons SET age = 2;")
                XCTAssertEqual(error.description, """
                    SQLite error 21: Multiple statements found. To execute multiple statements, \
                    use Database.execute(sql:) or Database.allStatements(sql:) instead. \
                    - while executing `UPDATE persons SET age = 1; UPDATE persons SET age = 2`
                    """)
            }
        }
    }

    func testMultipleStatementsWithSecondOneInvalidError() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            do {
                _ = try db.makeStatement(sql: "UPDATE persons SET age = 1;x")
                XCTFail("Expected error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_MISUSE)
                XCTAssertEqual(error.message!, """
                    Multiple statements found. To execute multiple statements, \
                    use Database.execute(sql:) or Database.allStatements(sql:) instead.
                    """)
                XCTAssertEqual(error.sql!, "UPDATE persons SET age = 1;x")
                XCTAssertEqual(error.description, """
                    SQLite error 21: Multiple statements found. To execute multiple statements, \
                    use Database.execute(sql:) or Database.allStatements(sql:) instead. \
                    - while executing `UPDATE persons SET age = 1;x`
                    """)
            }
        }
    }
    
    func testExecuteSQLLiteral() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.execute(literal: SQL(sql: """
                CREATE TABLE t(a);
                INSERT INTO t(a) VALUES (?);
                INSERT INTO t(a) VALUES (?);
                """, arguments: [1, 2]))
            let value = try Int.fetchOne(db, sql: "SELECT SUM(a) FROM t")
            XCTAssertEqual(value, 3)
        }
    }
    
    func testExecuteSQLLiteralWithInterpolation() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.execute(literal: """
                CREATE TABLE t(a);
                INSERT INTO t(a) VALUES (\(1));
                INSERT INTO t(a) VALUES (\(2));
                """)
            let value = try Int.fetchOne(db, sql: "SELECT SUM(a) FROM t")
            XCTAssertEqual(value, 3)
        }
    }
    
    // MARK: - SQLITE_STATIC vs SQLITE_TRANSIENT
    

    

    

    

}
