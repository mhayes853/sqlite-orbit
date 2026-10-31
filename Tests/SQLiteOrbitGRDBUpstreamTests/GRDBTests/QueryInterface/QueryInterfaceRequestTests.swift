// Generated from GRDB 7.11.1 Tests/GRDBTests/QueryInterface/QueryInterfaceRequestTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

private struct Reader : TableRecord {
    struct Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let age = Column("age")
        static let readerId = Column("readerId")
    }

    static let databaseTableName = "readers"
}
private typealias Columns = Reader.Columns
private let tableRequest = Reader.all()

class QueryInterfaceRequestTests: GRDBTestCase {
    
    let collation = DatabaseCollation("localized_case_insensitive") { (lhs, rhs) in
        return (lhs as NSString).localizedCaseInsensitiveCompare(rhs)
    }
    
    override func setUp() {
        super.setUp()
        dbConfiguration.prepareDatabase { db in
            db.add(collation: self.collation)
        }
    }
    
    override func setup(_ dbWriter: some DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createReaders") { db in
            try db.execute(sql: """
                CREATE TABLE readers (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    age INT)
                """)
        }
        try migrator.migrate(dbWriter)
    }
    
    // MARK: - Preparation
    
    func testSimpleRequestDoesNotUseAnyRowAdapter() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let adapter = try Reader.all().makePreparedRequest(db, forSingleResult: false).adapter
            XCTAssertNil(adapter)
        }
    }
    
    // MARK: - Fetch rows
    
    func testFetchRowFromRequest() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Arthur", 42])
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Barbara", 36])
            
            do {
                let rows = try Row.fetchAll(db, tableRequest)
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\"")
                XCTAssertEqual(rows.count, 2)
                XCTAssertEqual(rows[0]["id"] as Int64, 1)
                XCTAssertEqual(rows[0]["name"] as String, "Arthur")
                XCTAssertEqual(rows[0]["age"] as Int, 42)
                XCTAssertEqual(rows[1]["id"] as Int64, 2)
                XCTAssertEqual(rows[1]["name"] as String, "Barbara")
                XCTAssertEqual(rows[1]["age"] as Int, 36)
            }
            
            do {
                let row = try Row.fetchOne(db, tableRequest)!
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" LIMIT 1")
                XCTAssertEqual(row["id"] as Int64, 1)
                XCTAssertEqual(row["name"] as String, "Arthur")
                XCTAssertEqual(row["age"] as Int, 42)
            }
            
            do {
                var names: [String] = []
                let rows = try Row.fetchCursor(db, tableRequest)
                while let row = try rows.next() {
                    names.append(row["name"])
                }
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\"")
                XCTAssertEqual(names, ["Arthur", "Barbara"])
            }
        }
    }
    
    
    // MARK: - Count
    

    

    
    
    // MARK: - Select
    
    func testSelectLiteral() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Arthur", 42])
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Barbara", 36])
            
            let request = tableRequest.select(sql: "name, id - 1")
            let rows = try Row.fetchAll(db, request)
            XCTAssertEqual(lastSQLQuery, "SELECT name, id - 1 FROM \"readers\"")
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0][0] as String, "Arthur")
            XCTAssertEqual(rows[0][1] as Int64, 0)
            XCTAssertEqual(rows[1][0] as String, "Barbara")
            XCTAssertEqual(rows[1][1] as Int64, 1)
        }
    }
    
    func testSelectLiteralWithPositionalArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Arthur", 42])
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Barbara", 36])
            
            let request = tableRequest.select(sql: "name, id - ?", arguments: [1])
            let rows = try Row.fetchAll(db, request)
            XCTAssertEqual(lastSQLQuery, "SELECT name, id - 1 FROM \"readers\"")
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0][0] as String, "Arthur")
            XCTAssertEqual(rows[0][1] as Int64, 0)
            XCTAssertEqual(rows[1][0] as String, "Barbara")
            XCTAssertEqual(rows[1][1] as Int64, 1)
        }
    }
    
    func testSelectLiteralWithNamedArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Arthur", 42])
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Barbara", 36])
            
            let request = tableRequest.select(sql: "name, id - :n", arguments: ["n": 1])
            let rows = try Row.fetchAll(db, request)
            XCTAssertEqual(lastSQLQuery, "SELECT name, id - 1 FROM \"readers\"")
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0][0] as String, "Arthur")
            XCTAssertEqual(rows[0][1] as Int64, 0)
            XCTAssertEqual(rows[1][0] as String, "Barbara")
            XCTAssertEqual(rows[1][1] as Int64, 1)
        }
    }
    
    func testSelectSQLLiteral() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Arthur", 42])
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Barbara", 36])
            
            func test(_ request: QueryInterfaceRequest<Reader>) throws {
                let rows = try Row.fetchAll(db, request)
                XCTAssertEqual(rows.count, 2)
                XCTAssertEqual(rows[0][0] as String, "O'Brien")
                XCTAssertEqual(rows[0][1] as Int64, 0)
                XCTAssertEqual(rows[1][0] as String, "O'Brien")
                XCTAssertEqual(rows[1][1] as Int64, 1)
            }
            try test(tableRequest.select(literal: SQL(sql: ":name, id - :value", arguments: ["name": "O'Brien", "value": 1])))
            // Interpolation
            try test(tableRequest.select(literal: "\("O'Brien"), id - \(1)"))
        }
    }
    

    

    

    

    

    

    

    
    
    // MARK: - Distinct
    

    
    
    // MARK: - Filter
    
    func testFilterLiteral() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.filter(sql: "id <> 1")),
            "SELECT * FROM \"readers\" WHERE id <> 1")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.filter(sql: "id <> 1").filter(true.databaseValue)),
            "SELECT * FROM \"readers\" WHERE (id <> 1) AND 1")
    }
    
    func testFilterLiteralWithPositionalArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.filter(sql: "id <> ?", arguments: [1])),
            "SELECT * FROM \"readers\" WHERE id <> 1")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.filter(sql: "id <> ?", arguments: [1]).filter(true.databaseValue)),
            "SELECT * FROM \"readers\" WHERE (id <> 1) AND 1")
    }
    
    func testFilterLiteralWithNamedArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.filter(sql: "id <> :id", arguments: ["id": 1])),
            "SELECT * FROM \"readers\" WHERE id <> 1")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.filter(sql: "id <> :id", arguments: ["id": 1]).filter(true.databaseValue)),
            "SELECT * FROM \"readers\" WHERE (id <> 1) AND 1")
    }
    
    func testFilterLiteralWithMixedArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest
                .filter(sql: "age > :age", arguments: ["age": 20])
                .filter(sql: "name = ?", arguments: ["arthur"])),
            "SELECT * FROM \"readers\" WHERE (age > 20) AND (name = 'arthur')")
        XCTAssertEqual(
            sql(dbQueue, tableRequest
                .filter(sql: "age > ?", arguments: [20])
                .filter(sql: "name = :name", arguments: ["name": "arthur"])),
            "SELECT * FROM \"readers\" WHERE (age > 20) AND (name = 'arthur')")
    }
    
    func testFilter() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.filter(true.databaseValue)),
            "SELECT * FROM \"readers\" WHERE 1")
    }
    
    func testMultipleFilter() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.filter(true.databaseValue).filter(false.databaseValue)),
            "SELECT * FROM \"readers\" WHERE 1 AND 0")
    }
    
    // Regression test for https://github.com/groue/GRDB.swift/issues/812
    func testFilterOnView() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: "CREATE VIEW v AS SELECT * FROM readers")
            struct ViewRecord: TableRecord, FetchableRecord, Decodable {
                static let databaseTableName = "v"
            }
            _ = try ViewRecord.filter(Column("id") == 1).fetchOne(db)
            XCTAssertEqual(
                lastSQLQuery,
                "SELECT * FROM \"v\" WHERE \"id\" = 1 LIMIT 1")
        }
    }
    
    
    // MARK: - Group
    
    func testGroupLiteral() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.group(sql: "age, lower(name)")),
            "SELECT * FROM \"readers\" GROUP BY age, lower(name)")
    }
    
    func testGroupLiteralWithPositionalArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.group(sql: "age + ?, lower(name)", arguments: [1])),
            "SELECT * FROM \"readers\" GROUP BY age + 1, lower(name)")
    }
    
    func testGroupLiteralWithNamedArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.group(sql: "age + :n, lower(name)", arguments: ["n": 1])),
            "SELECT * FROM \"readers\" GROUP BY age + 1, lower(name)")
    }
    

    

    
    
    // MARK: - Having
    
    func testHavingLiteral() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.group(Columns.name).having(sql: "min(age) > 18")),
            "SELECT * FROM \"readers\" GROUP BY \"name\" HAVING min(age) > 18")
    }
    
    func testHavingLiteralWithPositionalArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.group(Columns.name).having(sql: "min(age) > ?", arguments: [18])),
            "SELECT * FROM \"readers\" GROUP BY \"name\" HAVING min(age) > 18")
    }
    
    func testHavingLiteralWithNamedArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.group(Columns.name).having(sql: "min(age) > :age", arguments: ["age": 18])),
            "SELECT * FROM \"readers\" GROUP BY \"name\" HAVING min(age) > 18")
    }
    

    

    
    
    // MARK: - Sort
    
    func testSortLiteral() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.order(sql: "lower(name) desc")),
            "SELECT * FROM \"readers\" ORDER BY lower(name) desc")
    }
    
    func testSortLiteralWithPositionalArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.order(sql: "age + ?", arguments: [1])),
            "SELECT * FROM \"readers\" ORDER BY age + 1")
    }
    
    func testSortLiteralWithNamedArguments() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.order(sql: "age + :age", arguments: ["age": 1])),
            "SELECT * FROM \"readers\" ORDER BY age + 1")
    }
    

    

    

    
    
    // MARK: - Reverse
    

    

    

    
    
    // MARK: - Limit
    
    func testLimit() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.limit(1)),
            "SELECT * FROM \"readers\" LIMIT 1")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.limit(1, offset: 2)),
            "SELECT * FROM \"readers\" LIMIT 1 OFFSET 2")
    }
    
    func testMultipleLimit() throws {
        let dbQueue = try makeDatabaseQueue()
        XCTAssertEqual(
            sql(dbQueue, tableRequest.limit(1, offset: 2).limit(3)),
            "SELECT * FROM \"readers\" LIMIT 3")
    }
    
    // MARK: - FetchOne Optimization
    
    func testFetchOneLimitOptimization() throws {
        // Test that we avoid emitting "LIMIT 1" when possible
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.read { db in
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(key: 1))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE \"id\" = 1")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(Column("id") == 1))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE \"id\" = 1")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(Column("id") == nil))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE \"id\" IS NULL")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(Column("name") == "Arthur"))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE \"name\" = \'Arthur\' LIMIT 1")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(Column("id") == 1 && Column("name") == "Arthur"))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE (\"id\" = 1) AND (\"name\" = \'Arthur\')")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(Column("id") == 1).filter(Column("name") == "Arthur"))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE (\"id\" = 1) AND (\"name\" = \'Arthur\')")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(Column("id")))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE \"id\" LIMIT 1")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(Column("id") != 1))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE \"id\" <> 1 LIMIT 1")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(Column("id") == 1 && Column("id") == 2))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE (\"id\" = 1) AND (\"id\" = 2)")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.filter(Column("id") == 1 || Column("id") == 2))
                XCTAssertEqual(lastSQLQuery, "SELECT * FROM \"readers\" WHERE (\"id\" = 1) OR (\"id\" = 2) LIMIT 1")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.select(max(Column("id"))))
                XCTAssertEqual(lastSQLQuery, "SELECT MAX(\"id\") FROM \"readers\"")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.select(min(Column("age")).forKey("minAge"), max(Column("age")).forKey("maxAge")))
                XCTAssertEqual(lastSQLQuery, "SELECT MIN(\"age\") AS \"minAge\", MAX(\"age\") AS \"maxAge\" FROM \"readers\"")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.select(max(Column("age") + 1)))
                XCTAssertEqual(lastSQLQuery, "SELECT MAX(\"age\" + 1) FROM \"readers\"")
            }
            do {
                _ = try Row.fetchOne(db, tableRequest.select(max(Column("age")) + 1))
                XCTAssertEqual(lastSQLQuery, "SELECT MAX(\"age\") + 1 FROM \"readers\"")
            }
        }
    }
    
    // MARK: - Exists
    
    func testIsEmpty() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { db in
            try XCTAssertTrue(tableRequest.isEmpty(db))
            XCTAssertEqual(lastSQLQuery, "SELECT EXISTS (SELECT * FROM \"readers\")")

            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Arthur", 42])
            try db.execute(sql: "INSERT INTO readers (name, age) VALUES (?, ?)", arguments: ["Barbara", 36])
            
            try XCTAssertFalse(tableRequest.isEmpty(db))
            XCTAssertEqual(lastSQLQuery, "SELECT EXISTS (SELECT * FROM \"readers\")")

            try XCTAssertFalse(tableRequest.filter(Column("name") == "Arthur").isEmpty(db))
            XCTAssertEqual(lastSQLQuery, "SELECT EXISTS (SELECT * FROM \"readers\" WHERE \"name\" = 'Arthur')")
        }
    }
}
