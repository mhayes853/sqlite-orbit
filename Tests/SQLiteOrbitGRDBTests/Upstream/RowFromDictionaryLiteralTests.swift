// Selected test bodies from GRDB 7.11.1; see LICENSE and provenance.md.
import XCTest
import SQLiteOrbitGRDB
class RowFromDictionaryLiteralTests: GRDBTestCase {
    func testColumnOrderIsPreserved() {
        // Paramount for tests
        let row: Row = ["a": 0, "i": 8, "b": 1, "h": 7, "c": 2, "g": 6, "d": 3, "f": 5, "e": 4]
        XCTAssertEqual(Array(row.columnNames), ["a", "i", "b", "h", "c", "g", "d", "f", "e"])
    }
    func testDuplicateColumnNames() {
        // Paramount for tests
        let row: Row = ["a": 0, "a": 1]
        XCTAssertEqual(Array(row.columnNames), ["a", "a"])
        XCTAssertEqual(row["a"] as Int, 0)
    }
    func testRowCount() {
        let row: Row = ["a": 0, "b": 1, "c": 2]
        XCTAssertEqual(row.count, 3)
    }
    func testRowColumnNames() {
        let row: Row = ["a": 0, "b": 1, "c": 2]
        XCTAssertEqual(Array(row.columnNames).sorted(), ["a", "b", "c"])
    }
    func testRowDatabaseValues() {
        let row: Row = ["a": 0, "b": 1, "c": 2]
        XCTAssertEqual(row.databaseValues.sorted { Int.fromDatabaseValue($0)! < Int.fromDatabaseValue($1)! }, [0.databaseValue, 1.databaseValue, 2.databaseValue])
    }
    func testRowIsCaseInsensitive() {
        let row: Row = ["name": "foo"]
        XCTAssertEqual(row["name"] as DatabaseValue, "foo".databaseValue)
        XCTAssertEqual(row["NAME"] as DatabaseValue, "foo".databaseValue)
        XCTAssertEqual(row["NaMe"] as DatabaseValue, "foo".databaseValue)
        XCTAssertEqual(row["name"] as String, "foo")
        XCTAssertEqual(row["NAME"] as String, "foo")
        XCTAssertEqual(row["NaMe"] as String, "foo")
    }
    func testMissingColumn() {
        let row: Row = ["name": "foo"]
        XCTAssertFalse(row.hasColumn("missing"))
        XCTAssertTrue(row["missing"] as DatabaseValue? == nil)
        XCTAssertTrue(row["missing"] == nil)
    }
    func testRowHasColumnIsCaseInsensitive() {
        let row: Row = ["nAmE": "foo", "foo": 1]
        XCTAssertTrue(row.hasColumn("name"))
        XCTAssertTrue(row.hasColumn("NAME"))
        XCTAssertTrue(row.hasColumn("Name"))
        XCTAssertTrue(row.hasColumn("NaMe"))
        XCTAssertTrue(row.hasColumn("foo"))
        XCTAssertTrue(row.hasColumn("Foo"))
        XCTAssertTrue(row.hasColumn("FOO"))
    }
    func testCopy() {
        let row: Row = ["a": 0, "b": 1, "c": 2]
        
        let copiedRow = row.copy()
        XCTAssertEqual(copiedRow.count, 3)
        XCTAssertEqual(copiedRow["a"] as Int, 0)
        XCTAssertEqual(copiedRow["b"] as Int, 1)
        XCTAssertEqual(copiedRow["c"] as Int, 2)
    }
    func testEqualityWithCopy() {
        let row: Row = ["a": 0, "b": 1, "c": 2]
        
        let copiedRow = row.copy()
        XCTAssertEqual(row, copiedRow)
    }
}
