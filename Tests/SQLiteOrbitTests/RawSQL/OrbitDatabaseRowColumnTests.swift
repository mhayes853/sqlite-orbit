import SQLiteOrbit
import Testing

@Suite
struct OrbitDatabaseRowColumnTests {
  @Test
  func typedReadsInferPropertyTypesAndHonorRenames() throws {
    let row = ColumnRow(names: ["label", "id", "note"], values: ["Milk", 7, .null])
    let title: String = try row[column: \ColumnModel.title]
    let id: Int = try row[column: \ColumnModel.id]
    let notes: String? = try row[column: \ColumnModel.notes]
    #expect(title == "Milk")
    #expect(id == 7)
    #expect(notes == nil)
    #expect(row.columnIndex(for: \ColumnModel.title) == 0)
    #expect(row.columnIndex(for: \ColumnModel.id) == 1)
    #expect(row.columnIndex(for: \ColumnModel.notes) == 2)
  }

  @Test
  func missingOptionalAndUnmappedPropertiesThrowButIndexesReturnNil() throws {
    let row = ColumnRow(names: ["id"], values: [7])
    #expect(row.columnIndex(for: \ColumnModel.notes) == nil)
    let missing = #expect(throws: OrbitDatabaseColumnDecodingError.self) {
      try row[column: \ColumnModel.notes]
    }
    #expect(missing?.columnName == "note")
    #expect(missing?.columnIndex == nil)
    #expect(row.columnIndex(for: \ColumnModel.computed) == nil)
    let unmapped = #expect(throws: OrbitDatabaseColumnDecodingError.self) {
      try row[column: \ColumnModel.computed]
    }
    #expect(unmapped?.columnIndex == nil)
    #expect(unmapped?.reason.contains("mapped") == true)
  }

  @Test
  func conversionFailuresRetainColumnAndUnderlyingError() throws {
    let row = ColumnRow(names: ["label", "id"], values: ["Milk", "bad"])
    let error = #expect(throws: OrbitDatabaseColumnDecodingError.self) {
      try row[column: \ColumnModel.id]
    }
    #expect(error?.columnIndex == 1)
    #expect(error?.columnName == "id")
    #expect(error?.underlyingError is OrbitDatabaseValueConversionError)
  }
}

// Mapping does not require row conversion or a database table.
private struct ColumnModel: OrbitDatabaseRowColumns {
  let id: Int
  let title: String
  let notes: String?
  var computed: String { title }

  static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? {
    switch keyPath {
    case \Self.id: "id"
    case \Self.title: "label"
    case \Self.notes: "note"
    default: nil
    }
  }
}

private struct ColumnRow: OrbitDatabaseRow {
  let names: [String]
  let values: [OrbitDatabaseValue]
  var columnCount: Int { names.count }
  func columnName(at index: Int) -> String { names[index] }
  subscript(index: Int) -> OrbitDatabaseValue { values[index] }
}
