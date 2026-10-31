// Generated from GRDB 7.11.1 Tests/GRDBTests/QueryInterface/QueryInterfaceExpressionsTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

private struct Reader : TableRecord {
    static let databaseTableName = "readers"
    
    struct Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let age = Column("age")
        static let readerId = Column("readerId")
    }
}
private typealias Columns = Reader.Columns
private let tableRequest = Reader.all()

class QueryInterfaceExpressionsTests: GRDBTestCase {
    
    let collation = DatabaseCollation("localized_case_insensitive") { (lhs, rhs) in
        return (lhs as NSString).localizedCaseInsensitiveCompare(rhs)
    }
    
    let customFunction = DatabaseFunction("avgOf", pure: true) { dbValues in
        let sum = dbValues.compactMap { Int.fromDatabaseValue($0) }.reduce(0, +)
        return Double(sum) / Double(dbValues.count)
    }
    
    override func setUp() {
        super.setUp()
        dbConfiguration.prepareDatabase { db in
            db.add(collation: self.collation)
            db.add(function: self.customFunction)
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
    
    
    // MARK: - Boolean expressions
    

    

    



    



    

    

    

    

    

    

    

    

    

    

    



    

    

    

    

    

    

    

    

    

    


    
    // MARK: - String functions
    

    
    
    // MARK: - Arithmetic expressions
    

    

    

    

    

    

    

    

    
    
    // MARK: - Bitwise expressions
    

    

    

    

    

    

    


    // MARK: - IFNULL expression
    

    
    
    // MARK: - Aggregated expressions
    

    

    

    

    

    

    

    

    

    

    

    

    

    

    
#if GRDBCUSTOMSQLITE || SQLITE_HAS_CODEC
    func testSumExpression_order() throws {
        // Prevent SQLCipher failures
        guard Database.sqliteLibVersionNumber >= 3044000 else {
            throw XCTSkip("ORDER BY clause on aggregate functions is not available")
        }
        
        let dbQueue = try makeDatabaseQueue()
        
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select(sum(Columns.age, orderBy: Columns.age))),
            "SELECT SUM(\"age\" ORDER BY \"age\") FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select { sum($0.age, orderBy: $0.age) }),
            "SELECT SUM(\"age\" ORDER BY \"age\") FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select(sum(Columns.age / 2, orderBy: Columns.age.desc))),
            "SELECT SUM(\"age\" / 2 ORDER BY \"age\" DESC) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select { sum($0.age / 2, orderBy: $0.age.desc) }),
            "SELECT SUM(\"age\" / 2 ORDER BY \"age\" DESC) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select(sum(Columns.age, orderBy: Columns.age, filter: Columns.age > 0))),
            "SELECT SUM(\"age\" ORDER BY \"age\") FILTER (WHERE \"age\" > 0) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select { sum($0.age, orderBy: $0.age, filter: $0.age > 0) }),
            "SELECT SUM(\"age\" ORDER BY \"age\") FILTER (WHERE \"age\" > 0) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select(sum(Columns.age / 2, orderBy: Columns.age.desc, filter: Columns.age > 0))),
            "SELECT SUM(\"age\" / 2 ORDER BY \"age\" DESC) FILTER (WHERE \"age\" > 0) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select { sum($0.age / 2, orderBy: $0.age.desc, filter: $0.age > 0) }),
            "SELECT SUM(\"age\" / 2 ORDER BY \"age\" DESC) FILTER (WHERE \"age\" > 0) FROM \"readers\"")
    }
#endif
    

    

    
#if GRDBCUSTOMSQLITE || SQLITE_HAS_CODEC
    func testTotalExpression_order() throws {
        // Prevent SQLCipher failures
        guard Database.sqliteLibVersionNumber >= 3044000 else {
            throw XCTSkip("ORDER BY clause on aggregate functions is not available")
        }
        
        let dbQueue = try makeDatabaseQueue()

        XCTAssertEqual(
            sql(dbQueue, tableRequest.select(total(Columns.age, orderBy: Columns.age))),
            "SELECT TOTAL(\"age\" ORDER BY \"age\") FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select { total($0.age, orderBy: $0.age) }),
            "SELECT TOTAL(\"age\" ORDER BY \"age\") FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select(total(Columns.age / 2, orderBy: Columns.age.desc))),
            "SELECT TOTAL(\"age\" / 2 ORDER BY \"age\" DESC) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select { total($0.age / 2, orderBy: $0.age.desc) }),
            "SELECT TOTAL(\"age\" / 2 ORDER BY \"age\" DESC) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select(total(Columns.age, orderBy: Columns.age, filter: Columns.age > 0))),
            "SELECT TOTAL(\"age\" ORDER BY \"age\") FILTER (WHERE \"age\" > 0) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select { total($0.age, orderBy: $0.age, filter: $0.age > 0) }),
            "SELECT TOTAL(\"age\" ORDER BY \"age\") FILTER (WHERE \"age\" > 0) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select(total(Columns.age / 2, orderBy: Columns.age.desc, filter: Columns.age > 0))),
            "SELECT TOTAL(\"age\" / 2 ORDER BY \"age\" DESC) FILTER (WHERE \"age\" > 0) FROM \"readers\"")
        XCTAssertEqual(
            sql(dbQueue, tableRequest.select { total($0.age / 2, orderBy: $0.age.desc, filter: $0.age > 0) }),
            "SELECT TOTAL(\"age\" / 2 ORDER BY \"age\" DESC) FILTER (WHERE \"age\" > 0) FROM \"readers\"")
    }
#endif
    
    // MARK: - LIKE operator
    

    
    
    // MARK: - || concat operator
    


    
    // MARK: - Function
    

    
    // MARK: - SQLExpressionFastPrimaryKey
    

}
