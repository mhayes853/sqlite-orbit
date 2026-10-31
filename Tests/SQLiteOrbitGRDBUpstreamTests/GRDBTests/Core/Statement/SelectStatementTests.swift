// Generated from GRDB 7.11.1 Tests/GRDBTests/Core/Statement/SelectStatementTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest/ and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class SelectStatementTests : GRDBTestCase {
    
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
            
            try db.execute(sql: "INSERT INTO persons (name, age) VALUES (?,?)", arguments: ["Arthur", 41])
            try db.execute(sql: "INSERT INTO persons (name, age) VALUES (?,?)", arguments: ["Barbara", 26])
            try db.execute(sql: "INSERT INTO persons (name, age) VALUES (?,?)", arguments: ["Craig", 13])
        }
        try migrator.migrate(dbWriter)
    }
    

    

    
    func testArrayStatementArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let statement = try db.makeStatement(sql: "SELECT COUNT(*) FROM persons WHERE age < ?")
            let ages = [20, 30, 40, 50]
            let counts = try ages.map { try Int.fetchOne(statement, arguments: [$0])! }
            XCTAssertEqual(counts, [1,2,2,3])
        }
    }

    func testStatementArgumentsSetterWithArray() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let statement = try db.makeStatement(sql: "SELECT COUNT(*) FROM persons WHERE age < ?")
            let ages = [20, 30, 40, 50]
            let counts = try ages.map { (age: Int) -> Int in
                statement.arguments = [age]
                return try Int.fetchOne(statement)!
            }
            XCTAssertEqual(counts, [1,2,2,3])
        }
    }

    func testDictionaryStatementArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let statement = try db.makeStatement(sql: "SELECT COUNT(*) FROM persons WHERE age < :age")
            let ageDicts: [[String: (any DatabaseValueConvertible)?]] = [["age": 20], ["age": 30], ["age": 40], ["age": 50]]
            let counts = try ageDicts.map { dic -> Int in
                // Make sure we don't trigger a failible initializer
                let arguments: StatementArguments = StatementArguments(dic)
                return try Int.fetchOne(statement, arguments: arguments)!
            }
            XCTAssertEqual(counts, [1,2,2,3])
        }
    }

    func testStatementArgumentsSetterWithDictionary() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let statement = try db.makeStatement(sql: "SELECT COUNT(*) FROM persons WHERE age < :age")
            let ageDicts: [[String: (any DatabaseValueConvertible)?]] = [["age": 20], ["age": 30], ["age": 40], ["age": 50]]
            let counts = try ageDicts.map { ageDict -> Int in
                statement.arguments = StatementArguments(ageDict)
                return try Int.fetchOne(statement)!
            }
            XCTAssertEqual(counts, [1,2,2,3])
        }
    }

    func testDatabaseErrorThrownBySelectStatementContainSQL() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            do {
                _ = try db.makeStatement(sql: "SELECT * FROM blah")
                XCTFail()
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message!, "no such table: blah")
                XCTAssertEqual(error.sql!, "SELECT * FROM blah")
                XCTAssertEqual(error.description, "SQLite error 1: no such table: blah - while executing `SELECT * FROM blah`")
            }
        }
    }

    func testCachedSelectStatementStepFailure() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let needsThrowMutex = Mutex(false)
            db.add(function: DatabaseFunction("bomb", argumentCount: 0, pure: false) { _ in
                if needsThrowMutex.load() {
                    throw DatabaseError(message: "boom")
                }
                return "success"
            })
            let sql = "SELECT bomb()"
            
            needsThrowMutex.store(false)
            XCTAssertEqual(try String.fetchAll(db.cachedStatement(sql: sql)), ["success"])
            
            do {
                needsThrowMutex.store(true)
                _ = try String.fetchAll(db.cachedStatement(sql: sql))
                XCTFail()
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message!, "boom")
                XCTAssertEqual(error.sql!, sql)
                XCTAssertEqual(error.description, "SQLite error 1: boom - while executing `\(sql)`")
            }
            
            needsThrowMutex.store(false)
            XCTAssertEqual(try String.fetchAll(db.cachedStatement(sql: sql)), ["success"])
        }
    }
    
    func testConsumeMultipleStatements() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            do {
                // SQL, no argument
                let statements = try db.allStatements(sql: """
                    SELECT age FROM persons ORDER BY age;
                    SELECT age FROM persons ORDER BY age DESC;
                    """)
                let ages = try Array(statements.flatMap { try Int.fetchCursor($0) })
                XCTAssertEqual(ages, [13, 26, 41, 41, 26, 13])
            }
            do {
                // Literal, no argument
                let statements = try db.allStatements(literal: """
                    SELECT age FROM persons ORDER BY age;
                    SELECT age FROM persons ORDER BY age DESC;
                    """)
                let ages = try Array(statements.flatMap { try Int.fetchCursor($0) })
                XCTAssertEqual(ages, [13, 26, 41, 41, 26, 13])
            }
            
            do {
                // SQL, missing arguments
                let statements = try db.allStatements(sql: """
                    SELECT count(*) FROM persons WHERE age > ?;
                    SELECT count(*) FROM persons WHERE age < ?;
                    """)
                let counts = try Array(statements.map { try
                    Int.fetchOne($0, arguments: [30])!
                })
                XCTAssertEqual(counts, [1, 2])
            }
            do {
                // Literal, missing arguments
                let statements = try db.allStatements(literal: """
                    SELECT count(*) FROM persons WHERE age > ?;
                    SELECT count(*) FROM persons WHERE age < ?;
                    """)
                let counts = try Array(statements.map { try
                    Int.fetchOne($0, arguments: [30])!
                })
                XCTAssertEqual(counts, [1, 2])
            }
            
            do {
                // SQL, matching arguments
                let statements = try db.allStatements(sql: """
                    SELECT name FROM persons WHERE name = ?;
                    SELECT name FROM persons WHERE age > ? ORDER BY name;
                    """, arguments: ["Arthur", 20])
                let names = try Array(statements.map { try String.fetchAll($0) })
                XCTAssertEqual(names, [["Arthur"], ["Arthur", "Barbara"]])
            }
            do {
                // Literal, matching arguments
                let statements = try db.allStatements(literal: """
                    SELECT name FROM persons WHERE name = \("Arthur");
                    SELECT name FROM persons WHERE age > \(20) ORDER BY name;
                    """)
                let names = try Array(statements.map { try String.fetchAll($0) })
                XCTAssertEqual(names, [["Arthur"], ["Arthur", "Barbara"]])
            }
            
            do {
                // SQL, too few arguments
                let statements = try db.allStatements(sql: """
                    SELECT name FROM persons WHERE name = ?;
                    SELECT name FROM persons WHERE age > ? ORDER BY name;
                    """, arguments: ["Arthur"])
                _ = try Array(statements.map { try String.fetchAll($0) })
                XCTFail("Expected Error")
            } catch DatabaseError.SQLITE_MISUSE {
                // OK
            }
            do {
                // Literal, too few arguments
                let statements = try db.allStatements(literal: """
                    SELECT name FROM persons WHERE name = \("Arthur");
                    SELECT name FROM persons WHERE age > ? ORDER BY name;
                    """)
                _ = try Array(statements.map { try String.fetchAll($0) })
                XCTFail("Expected Error")
            } catch DatabaseError.SQLITE_MISUSE {
                // OK
            }
            
            do {
                // SQL, too many arguments
                let statements = try db.allStatements(sql: """
                    SELECT name FROM persons WHERE name = ?;
                    SELECT name FROM persons WHERE age > ? ORDER BY name;
                    """, arguments: ["Arthur", 20, 55])
                _ = try Array(statements.map { try String.fetchAll($0) })
                XCTFail("Expected Error")
            } catch DatabaseError.SQLITE_MISUSE {
                // OK
            }
            
            do {
                // Mix statement kinds
                let statements = try db.allStatements(literal: """
                    CREATE TABLE t(a);
                    INSERT INTO t VALUES (0);
                    SELECT a FROM t ORDER BY a;
                    INSERT INTO t VALUES (1);
                    SELECT a FROM t ORDER BY a;
                    """)
                let values = try Array(statements.map { try Int.fetchAll($0) })
                XCTAssertEqual(values, [[], [], [0], [], [0, 1]])
            }
        }
    }
    

}
