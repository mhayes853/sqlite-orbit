// Generated from GRDB 7.11.1 Tests/GRDBTests/QueryInterface/TableDefinitionTests.swift by Tests/GRDBReference/grdb_upstream.py.
// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.
import XCTest
import SQLiteOrbitGRDB

class TableDefinitionTests: GRDBTestCase {
    
    func testCreateTable() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            // Simple table creation
            try db.create(table: "test") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text)
            }
            
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" (\
                "id" INTEGER PRIMARY KEY, \
                "name" TEXT\
                )
                """)
        }
    }
    



    

    
    func testUntypedColumn() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            // Simple table creation
            try db.create(table: "test") { t in
                t.column("a")
                t.column("b")
            }
            
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" ("a", "b")
                """)
        }
    }
    

    

    
    func testColumnNotNull() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.column("a", .integer).notNull()
                t.column("b", .integer).notNull(onConflict: .abort)
                t.column("c", .integer).notNull(onConflict: .rollback)
                t.column("d", .integer).notNull(onConflict: .fail)
                t.column("e", .integer).notNull(onConflict: .ignore)
                t.column("f", .integer).notNull(onConflict: .replace)
            }
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" (\
                "a" INTEGER NOT NULL, \
                "b" INTEGER NOT NULL, \
                "c" INTEGER NOT NULL ON CONFLICT ROLLBACK, \
                "d" INTEGER NOT NULL ON CONFLICT FAIL, \
                "e" INTEGER NOT NULL ON CONFLICT IGNORE, \
                "f" INTEGER NOT NULL ON CONFLICT REPLACE\
                )
                """)
        }
    }
    
    func testColumnIndexed() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            clearSQLQueries()
            try db.create(table: "test") { t in
                t.column("a", .integer).indexed()
                t.column("b", .integer).indexed()
            }
            assertEqualSQL(sqlQueries[0], "CREATE TABLE \"test\" (\"a\" INTEGER, \"b\" INTEGER)")
            assertEqualSQL(sqlQueries[1], "CREATE INDEX \"test_on_a\" ON \"test\"(\"a\")")
            assertEqualSQL(sqlQueries[2], "CREATE INDEX \"test_on_b\" ON \"test\"(\"b\")")
        }
    }
    
    // Regression test for https://github.com/groue/GRDB.swift/issues/838
    func testColumnIndexedInheritsIfNotExistsFlag() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            clearSQLQueries()
            try db.create(table: "test", options: [.ifNotExists]) { t in
                t.column("a", .integer).indexed()
                t.column("b", .integer).indexed()
            }
            assertEqualSQL(sqlQueries[0], "CREATE TABLE IF NOT EXISTS \"test\" (\"a\" INTEGER, \"b\" INTEGER)")
            assertEqualSQL(sqlQueries[1], "CREATE INDEX IF NOT EXISTS \"test_on_a\" ON \"test\"(\"a\")")
            assertEqualSQL(sqlQueries[2], "CREATE INDEX IF NOT EXISTS \"test_on_b\" ON \"test\"(\"b\")")
        }
    }
    
    func testColumnUnique() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.column("a", .integer).unique()
                t.column("b", .integer).unique(onConflict: .abort)
                t.column("c", .integer).unique(onConflict: .rollback)
                t.column("d", .integer).unique(onConflict: .fail)
                t.column("e", .integer).unique(onConflict: .ignore)
                t.column("f", .integer).unique(onConflict: .replace)
            }
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" (\
                "a" INTEGER UNIQUE, \
                "b" INTEGER UNIQUE, \
                "c" INTEGER UNIQUE ON CONFLICT ROLLBACK, \
                "d" INTEGER UNIQUE ON CONFLICT FAIL, \
                "e" INTEGER UNIQUE ON CONFLICT IGNORE, \
                "f" INTEGER UNIQUE ON CONFLICT REPLACE\
                )
                """)
        }
    }
    
    func testColumnCheck() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.column("a", .integer).check { $0 > 0 }
                t.column("b", .integer).check(sql: "b <> 2")
                t.column("c", .integer).check { $0 > 0 }.check { $0 < 10 }
                t.column("d", .integer).check { $0 != Column("c") }
            }
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" (\
                "a" INTEGER CHECK ("a" > 0), \
                "b" INTEGER CHECK (b <> 2), \
                "c" INTEGER CHECK ("c" > 0) CHECK ("c" < 10), \
                "d" INTEGER CHECK ("d" <> "c")\
                )
                """)

            // Sanity check
            try db.execute(sql: "INSERT INTO test (a, b, c) VALUES (1, 0, 1)")
            do {
                try db.execute(sql: "INSERT INTO test (a, b, c) VALUES (0, 0, 1)")
                XCTFail()
            } catch {
            }
        }
    }
    
    func testColumnDefault() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.column("a", .integer).defaults(to: 1)
                t.column("b", .integer).defaults(to: 1.0)
                t.column("c", .integer).defaults(to: "'fooéı👨👨🏿🇫🇷🇨🇮'")
                t.column("d", .integer).defaults(to: "foo".data(using: .utf8)!)
                t.column("e", .integer).defaults(sql: "NULL")
            }
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" (\
                "a" INTEGER DEFAULT 1, \
                "b" INTEGER DEFAULT 1.0, \
                "c" INTEGER DEFAULT '''fooéı👨👨🏿🇫🇷🇨🇮''', \
                "d" INTEGER DEFAULT X'666F6F', \
                "e" INTEGER DEFAULT NULL\
                )
                """)

            // Sanity check
            try db.execute(sql: "INSERT INTO test DEFAULT VALUES")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT a FROM test")!, 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT c FROM test")!, "'fooéı👨👨🏿🇫🇷🇨🇮'")
        }
    }
    

    
    func testColumnReference() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "parent") { t in
                t.primaryKey("name", .text)
                t.column("email", .text).unique()
            }
            try db.create(table: "pkless") { t in
                t.column("email", .text)
            }
            try db.create(table: "child") { t in
                t.column("parentName", .text).references("parent", onDelete: .cascade, onUpdate: .cascade)
                t.column("parentEmail", .text).references("parent", column: "email", onDelete: .restrict, deferred: true)
                t.column("weird", .text).references("parent", column: "name").references("parent", column: "email")
                t.column("pklessRowId", .text).references("pkless")
            }
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "child" (\
                "parentName" TEXT REFERENCES "parent"("name") ON DELETE CASCADE ON UPDATE CASCADE, \
                "parentEmail" TEXT REFERENCES "parent"("email") ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED, \
                "weird" TEXT REFERENCES "parent"("name") REFERENCES "parent"("email"), \
                "pklessRowId" TEXT REFERENCES "pkless"("rowid")\
                )
                """)
        }
    }
    

    

    
    func testTableUniqueKey() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.uniqueKey(["a"])
                t.uniqueKey(["b", "c"], onConflict: .fail)
                t.column("a", .text)
                t.column("b", .text)
                t.column("c", .text)
            }
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" (\
                "a" TEXT, \
                "b" TEXT, \
                "c" TEXT, \
                UNIQUE ("a"), \
                UNIQUE ("b", "c") ON CONFLICT FAIL\
                )
                """)
        }
    }
    

    
    func testTableCheck() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.check(Column("a") + Column("b") < 10)
                t.check(sql: "a + b < 10")
                t.column("a", .integer)
                t.column("b", .integer)
            }
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" (\
                "a" INTEGER, \
                "b" INTEGER, \
                CHECK (("a" + "b") < 10), \
                CHECK (a + b < 10)\
                )
                """)
            
            // Sanity check
            try db.execute(sql: "INSERT INTO test (a, b) VALUES (1, 0)")
            do {
                try db.execute(sql: "INSERT INTO test (a, b) VALUES (5, 5)")
                XCTFail()
            } catch {
            }
        }
    }
    
    @available(*, deprecated)
    func testTableCheck_deprecated() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                // Deprecated because this does not what the user means!
                t.check("a < b")
                t.column("a", .integer)
                t.column("b", .integer)
            }
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" (\
                "a" INTEGER, \
                "b" INTEGER, \
                CHECK ('a < b')\
                )
                """)
            
            // Sanity check: insert should fail because the 'a < b' string is false for SQLite
            do {
                try db.execute(sql: "INSERT INTO test (a, b) VALUES (0, 1)")
                XCTFail()
            } catch {
            }
        }
    }
    
    func testConstraintLiteral() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            // Simple table creation
            try db.create(table: "test") { t in
                t.constraint(sql: "CHECK (a + b < 10)")
                t.constraint(sql: "CHECK (a + b < \(20))")
                t.column("a", .integer)
                t.column("b", .integer)
            }
            
            assertEqualSQL(lastSQLQuery!, """
                CREATE TABLE "test" (\
                "a" INTEGER, \
                "b" INTEGER, \
                CHECK (a + b < 10), \
                CHECK (a + b < 20)\
                )
                """)
        }
    }
    

    
    func testRenameTable() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.column("a", .text)
            }
            XCTAssertTrue(try db.tableExists("test"))
            XCTAssertEqual(try db.columns(in: "test").count, 1)
            
            try db.rename(table: "test", to: "foo")
            assertEqualSQL(lastSQLQuery!, "ALTER TABLE \"test\" RENAME TO \"foo\"")
            XCTAssertFalse(try db.tableExists("test"))
            XCTAssertTrue(try db.tableExists("foo"))
            XCTAssertEqual(try db.columns(in: "foo").count, 1)
        }
    }
    

    
    func testAlterTableAddAutoReferencingForeignKey() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            do {
                try db.create(table: "hiddenRowIdTable") { t in
                    t.column("a", .text)
                }
                
                clearSQLQueries()
                try db.alter(table: "hiddenRowIdTable") { t in
                    t.add(column: "ref").references("hiddenRowIdTable")
                }
                XCTAssertEqual(lastSQLQuery, """
                    ALTER TABLE "hiddenRowIdTable" ADD COLUMN "ref" REFERENCES "hiddenRowIdTable"("rowid")
                    """)
            }
            
            do {
                try db.create(table: "explicitPrimaryKey") { t in
                    t.primaryKey("code", .text)
                    t.column("a", .text)
                }
                
                clearSQLQueries()
                try db.alter(table: "explicitPrimaryKey") { t in
                    t.add(column: "ref").references("explicitPrimaryKey")
                }
                XCTAssertEqual(lastSQLQuery, """
                    ALTER TABLE "explicitPrimaryKey" ADD COLUMN "ref" REFERENCES "explicitPrimaryKey"("code")
                    """)
            }
        }
    }
    
    func testAlterTableAddColumnInvalidatesSchemaCache() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.column("a", .text)
            }
            try XCTAssertEqual(db.columns(in: "test").map(\.name), ["a"])

            try db.alter(table: "test") { t in
                t.add(column: "b", .text)
            }
            try XCTAssertEqual(db.columns(in: "test").map(\.name), ["a", "b"])
        }
    }




    
    func testAlterTableAddGeneratedVirtualColumn() throws {
#if GRDBCUSTOMSQLITE || SQLITE_HAS_CODEC
        guard Database.sqliteLibVersionNumber >= 3031000 else {
            throw XCTSkip("Generated columns are not available")
        }
#else
        guard #available(iOS 15, macOS 12, tvOS 15, watchOS 8, *) else {
            throw XCTSkip("Generated columns are not available")
        }
#endif
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.column("a", .integer)
                t.column("b", .integer)
                t.column("c", .text)
            }
            
            clearSQLQueries()
            try db.alter(table: "test") { t in
                t.add(column: "d", .integer).generatedAs(sql: "a*abs(b)", .virtual)
                t.add(column: "e", .text).generatedAs(sql: "substr(c,b,b+1)", .virtual)
                t.add(column: "f").generatedAs(sql: "e", .virtual)
                t.add(column: "g").generatedAs(Column("a") * 2)
                t.add(column: "h").generatedAs("O'Brien")
            }
            
            let latestQueries = Array(sqlQueries.suffix(5))
            assertEqualSQL(latestQueries[0], "ALTER TABLE \"test\" ADD COLUMN \"d\" INTEGER GENERATED ALWAYS AS (a*abs(b)) VIRTUAL")
            assertEqualSQL(latestQueries[1], "ALTER TABLE \"test\" ADD COLUMN \"e\" TEXT GENERATED ALWAYS AS (substr(c,b,b+1)) VIRTUAL")
            assertEqualSQL(latestQueries[2], "ALTER TABLE \"test\" ADD COLUMN \"f\" GENERATED ALWAYS AS (e) VIRTUAL")
            assertEqualSQL(latestQueries[3], "ALTER TABLE \"test\" ADD COLUMN \"g\" GENERATED ALWAYS AS (\"a\" * 2) VIRTUAL")
            assertEqualSQL(latestQueries[4], "ALTER TABLE \"test\" ADD COLUMN \"h\" GENERATED ALWAYS AS ('O''Brien') VIRTUAL")
        }
    }
    

    

    
    func testDropTable() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text)
            }
            XCTAssertTrue(try db.tableExists("test"))
            XCTAssertEqual(try db.columns(in: "test").count, 2)
            
            try db.drop(table: "test")
            assertEqualSQL(lastSQLQuery!, "DROP TABLE \"test\"")
            XCTAssertFalse(try db.tableExists("test"))
        }
    }
    
    func testCreateIndex() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.primaryKey("id", .integer)
                t.column("a", .text)
                t.column("b", .text)
            }
            
            try db.create(index: "test_on_a", on: "test", columns: ["a"])
            assertEqualSQL(lastSQLQuery!, "CREATE INDEX \"test_on_a\" ON \"test\"(\"a\")")
            
            try db.create(index: "test_on_a_b", on: "test", columns: ["a", "b"], unique: true, ifNotExists: true)
            assertEqualSQL(lastSQLQuery!, "CREATE UNIQUE INDEX IF NOT EXISTS \"test_on_a_b\" ON \"test\"(\"a\", \"b\")")
            
            try db.create(index: "test_on_a_b_2", on: "test", columns: ["a", "b"], options: [.unique, .ifNotExists])
            assertEqualSQL(lastSQLQuery!, "CREATE UNIQUE INDEX IF NOT EXISTS \"test_on_a_b_2\" ON \"test\"(\"a\", \"b\")")
            
            try db.create(index: "test_on_a_plus_b", on: "test", expressions: [Column("a") + Column("b")], options: [.unique, .ifNotExists])
            assertEqualSQL(lastSQLQuery!, "CREATE UNIQUE INDEX IF NOT EXISTS \"test_on_a_plus_b\" ON \"test\"(\"a\" + \"b\")")
            
            try db.create(index: "test_on_a_nocase", on: "test", expressions: [Column("a").collating(.nocase)], options: [.unique, .ifNotExists])
            assertEqualSQL(lastSQLQuery!, "CREATE UNIQUE INDEX IF NOT EXISTS \"test_on_a_nocase\" ON \"test\"(\"a\" COLLATE NOCASE)")

            // Sanity check
            XCTAssertEqual(try Set(db.indexes(on: "test").map(\.name)), ["test_on_a", "test_on_a_b", "test_on_a_b_2", "test_on_a_nocase"])
        }
    }
    
    func testCreateIndexOn() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.primaryKey("id", .integer)
                t.column("a", .text)
                t.column("b", .text)
            }
            
            try db.create(indexOn: "test", columns: ["a"])
            assertEqualSQL(lastSQLQuery!, "CREATE INDEX \"index_test_on_a\" ON \"test\"(\"a\")")
            
            try db.create(indexOn: "test", columns: ["a", "b"], options: [.unique])
            assertEqualSQL(lastSQLQuery!, "CREATE UNIQUE INDEX \"index_test_on_a_b\" ON \"test\"(\"a\", \"b\")")
            
            try db.create(indexOn: "test", columns: ["b"], options: [.unique, .ifNotExists])
            assertEqualSQL(lastSQLQuery!, "CREATE UNIQUE INDEX IF NOT EXISTS \"index_test_on_b\" ON \"test\"(\"b\")")
            
            // Sanity check
            XCTAssertEqual(try Set(db.indexes(on: "test").map(\.name)), ["index_test_on_a", "index_test_on_a_b", "index_test_on_b"])
        }
    }
    
    func testCreatePartialIndex() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.primaryKey("id", .integer)
                t.column("a", .text)
                t.column("b", .text)
            }
            
            try db.create(index: "test_on_a_b", on: "test", columns: ["a", "b"], options: [.unique, .ifNotExists], condition: Column("a") == 1)
            assertEqualSQL(lastSQLQuery!, "CREATE UNIQUE INDEX IF NOT EXISTS \"test_on_a_b\" ON \"test\"(\"a\", \"b\") WHERE \"a\" = 1")
            
            try db.create(index: "test_on_a_plus_b", on: "test", expressions: [Column("a") + Column("b")], options: [.unique, .ifNotExists], condition: Column("a") == 1)
            assertEqualSQL(lastSQLQuery!, "CREATE UNIQUE INDEX IF NOT EXISTS \"test_on_a_plus_b\" ON \"test\"(\"a\" + \"b\") WHERE \"a\" = 1")
            
            // Sanity check
            XCTAssertEqual(try Set(db.indexes(on: "test").map(\.name)), ["test_on_a_b"])
        }
    }
    
    func testDropIndex() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text)
            }
            try db.create(index: "test_on_name", on: "test", columns: ["name"])
            
            try db.drop(index: "test_on_name")
            assertEqualSQL(lastSQLQuery!, "DROP INDEX \"test_on_name\"")
            
            // Sanity check
            XCTAssertTrue(try db.indexes(on: "test").isEmpty)
        }
    }
    
    func testDropIndexOn() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try db.create(table: "test") { t in
                t.primaryKey("id", .integer)
                t.column("a", .text)
                t.column("b", .text)
                t.column("c", .text)
                t.column("d", .text)
            }
            try db.create(index: "custom_name_a", on: "test", columns: ["a"])
            try db.create(index: "custom_name_b", on: "test", columns: ["a", "b"])
            try db.create(indexOn: "test", columns: ["c"])
            try db.create(indexOn: "test", columns: ["c", "d"])
            
            // Custom name
            try db.drop(indexOn: "test", columns: ["a"])
            assertEqualSQL(lastSQLQuery!, "DROP INDEX \"custom_name_a\"")
            
            // Custom name, case insensitivity
            try db.drop(indexOn: "TEST", columns: ["A", "B"])
            assertEqualSQL(lastSQLQuery!, "DROP INDEX \"custom_name_b\"")
            
            // Default name
            try db.drop(indexOn: "test", columns: ["c"])
            assertEqualSQL(lastSQLQuery!, "DROP INDEX \"index_test_on_c\"")
            
            // Default name, case insensitivity
            try db.drop(indexOn: "TEST", columns: ["C", "D"])
            assertEqualSQL(lastSQLQuery!, "DROP INDEX \"index_test_on_c_d\"")
            
            // Non existing index: no error
            try db.drop(indexOn: "test", columns: ["a", "b", "c", "d"])
            
            // Non existing table: error
            do {
                try db.drop(indexOn: "missing", columns: ["a"])
                XCTFail("Expected error")
            } catch { }

            // Sanity check
            XCTAssertTrue(try db.indexes(on: "test").isEmpty)
        }
    }


    

    

    

}
