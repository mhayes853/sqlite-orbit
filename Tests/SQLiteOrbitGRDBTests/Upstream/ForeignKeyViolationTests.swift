import XCTest
import SQLiteOrbitGRDB

class ForeignKeyViolationTests: GRDBTestCase {
    func testForeignKeyViolations() throws {
        try makeDatabaseQueue().writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE parent(id TEXT NOT NULL PRIMARY KEY);
                CREATE TABLE child1(id INTEGER NOT NULL PRIMARY KEY, parentId TEXT REFERENCES parent(id));
                CREATE TABLE child2(id INTEGER NOT NULL PRIMARY KEY, parentId TEXT REFERENCES parent(id));
                PRAGMA foreign_keys = OFF;
                INSERT INTO child1 (id, parentId) VALUES (13, '1');
                INSERT INTO child1 (id, parentId) VALUES (42, '2');
                INSERT INTO child2 (id, parentId) VALUES (17, '3');
                """)

            let violations = try Array(db.foreignKeyViolations())
            XCTAssertEqual(violations.count, 3)

            if let violation = violations.first(where: { $0.originTable == "child1" && $0.originRowID == 13 }) {
                XCTAssertEqual(violation.destinationTable, "parent")
            } else {
                XCTFail("Missing violation")
            }

            if let violation = violations.first(where: { $0.originTable == "child1" && $0.originRowID == 42 }) {
                XCTAssertEqual(violation.destinationTable, "parent")
            } else {
                XCTFail("Missing violation")
            }

            if let violation = violations.first(where: { $0.originTable == "child2" && $0.originRowID == 17 }) {
                XCTAssertEqual(violation.destinationTable, "parent")
            } else {
                XCTFail("Missing violation")
            }
        }
    }
        func testForeignKeyViolationsInTable() throws {
        try makeDatabaseQueue().writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE parent(id TEXT NOT NULL PRIMARY KEY);
                CREATE TABLE child1(id INTEGER NOT NULL PRIMARY KEY, parentId TEXT REFERENCES parent(id));
                CREATE TABLE child2(id INTEGER NOT NULL PRIMARY KEY, parentId TEXT REFERENCES parent(id));
                PRAGMA foreign_keys = OFF;
                INSERT INTO child1 (id, parentId) VALUES (13, '1');
                INSERT INTO child1 (id, parentId) VALUES (42, '2');
                INSERT INTO child2 (id, parentId) VALUES (17, '3');
                """)

            do {
                let violations = try Array(db.foreignKeyViolations(in: "child1"))
                XCTAssertEqual(violations.count, 2)

                if let violation = violations.first(where: { $0.originRowID == 13 }) {
                    XCTAssertEqual(violation.originTable, "child1")
                    XCTAssertEqual(violation.destinationTable, "parent")
                } else {
                    XCTFail("Missing violation")
                }

                if let violation = violations.first(where: { $0.originRowID == 42 }) {
                    XCTAssertEqual(violation.originTable, "child1")
                    XCTAssertEqual(violation.destinationTable, "parent")
                } else {
                    XCTFail("Missing violation")
                }
            }

            do {
                let violations = try Array(db.foreignKeyViolations(in: "child2"))
                XCTAssertEqual(violations.count, 1)

                if let violation = violations.first(where: { $0.originRowID == 17 }) {
                    XCTAssertEqual(violation.originTable, "child2")
                    XCTAssertEqual(violation.destinationTable, "parent")
                } else {
                    XCTFail("Missing violation")
                }
            }

            // Case insensitivity
            do {
                let violations = try Array(db.foreignKeyViolations(in: "cHiLd2"))
                XCTAssertEqual(violations.count, 1)

                if let violation = violations.first(where: { $0.originRowID == 17 }) {
                    XCTAssertEqual(violation.originTable, "child2")
                    XCTAssertEqual(violation.destinationTable, "parent")
                } else {
                    XCTFail("Missing violation")
                }
            }

            // Missing table
            do {
                _ = try db.foreignKeyViolations(in: "missing")
            } catch DatabaseError.SQLITE_ERROR { }
        }
    }
        func testCheckForeignKeys() throws {
        try makeDatabaseQueue().writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE parent(id TEXT NOT NULL PRIMARY KEY);
                CREATE TABLE child(id INTEGER NOT NULL PRIMARY KEY, parentId TEXT REFERENCES parent(id));
                PRAGMA foreign_keys = OFF;
                INSERT INTO child (id, parentId) VALUES (13, '1');
                """)

            do {
                try db.checkForeignKeys()
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
                XCTAssertEqual(error.extendedResultCode, .SQLITE_CONSTRAINT_FOREIGNKEY)
                XCTAssertEqual(error.message, #"FOREIGN KEY constraint violation - from child(parentId) to parent(id), in [id:13 parentId:"1"]"#)
                XCTAssertEqual(error.description, #"SQLite error 19: FOREIGN KEY constraint violation - from child(parentId) to parent(id), in [id:13 parentId:"1"]"#)
            }
        }

        try makeDatabaseQueue().writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE parent(a TEXT NOT NULL, b TEXT NOT NULL, PRIMARY KEY (a, b));
                CREATE TABLE child(id INTEGER NOT NULL PRIMARY KEY, parentA, parentB, FOREIGN KEY (parentA, parentB) REFERENCES parent(a, b));
                PRAGMA foreign_keys = OFF;
                INSERT INTO child (id, parentA, parentB) VALUES (13, 'foo', 'bar');
                """)

            do {
                try db.checkForeignKeys()
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
                XCTAssertEqual(error.extendedResultCode, .SQLITE_CONSTRAINT_FOREIGNKEY)
                XCTAssertEqual(error.message, #"FOREIGN KEY constraint violation - from child(parentA, parentB) to parent(a, b), in [id:13 parentA:"foo" parentB:"bar"]"#)
                XCTAssertEqual(error.description, #"SQLite error 19: FOREIGN KEY constraint violation - from child(parentA, parentB) to parent(a, b), in [id:13 parentA:"foo" parentB:"bar"]"#)
            }
        }

        try makeDatabaseQueue().writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE parent(a TEXT NOT NULL, b TEXT NOT NULL, PRIMARY KEY (a, b));
                CREATE TABLE child(id INTEGER NOT NULL PRIMARY KEY, parentA, parentB, FOREIGN KEY (parentA, parentB) REFERENCES parent(a, b)) WITHOUT ROWID;
                PRAGMA foreign_keys = OFF;
                INSERT INTO child (id, parentA, parentB) VALUES (13, 'foo', 'bar');
                """)

            do {
                try db.checkForeignKeys()
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
                XCTAssertEqual(error.extendedResultCode, .SQLITE_CONSTRAINT_FOREIGNKEY)
                XCTAssertEqual(error.message, "FOREIGN KEY constraint violation - from child(parentA, parentB) to parent(a, b)")
                XCTAssertEqual(error.description, "SQLite error 19: FOREIGN KEY constraint violation - from child(parentA, parentB) to parent(a, b)")
            }
        }
    }
        func testForeignKeyViolationsUnknownSchema() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE parent (id PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE child (parentId REFERENCES parent)")
            do {
                _ = try db.foreignKeyViolations(in: "child", in: "invalid")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message, "no such schema: invalid")
                XCTAssertEqual(error.description, "SQLite error 1: no such schema: invalid")
            }

            do {
                _ = try db.checkForeignKeys(in: "child", in: "invalid")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
                XCTAssertEqual(error.message, "no such schema: invalid")
                XCTAssertEqual(error.description, "SQLite error 1: no such schema: invalid")
            }
        }
    }
        func testForeignKeyViolationsMainSchema() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TABLE parent(id TEXT NOT NULL PRIMARY KEY);
                CREATE TABLE child(id INTEGER NOT NULL PRIMARY KEY, parentId TEXT REFERENCES parent(id));
                PRAGMA foreign_keys = OFF;
                INSERT INTO child (id, parentId) VALUES (13, '1');
                """)
            do {
                let violations = try Array(db.foreignKeyViolations(in: "child", in: "main"))
                XCTAssertEqual(violations.count, 1)
            }
            do {
                _ = try db.checkForeignKeys(in: "child", in: "main")
                XCTFail("Expected Error")
            } catch let error as DatabaseError {
                XCTAssertEqual(DatabaseError.SQLITE_CONSTRAINT_FOREIGNKEY, error.extendedResultCode)
            }
        }
    }

}
