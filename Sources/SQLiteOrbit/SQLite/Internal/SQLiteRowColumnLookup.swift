/// A cursor's lazily prepared column mapping, shared by its borrowed rows.
///
/// Preparation happens on the first named lookup, after SQLite has stepped and had the chance to
/// recompile its statement. A new cursor always gets a new mapping, even for a cached statement.
@usableFromInline
final class SQLiteRowColumnLookup {
  // Swift String equality normalizes Unicode. SQL result names instead match their UTF-8 bytes,
  // just as the native named subscript did before this lookup was cached.
  private struct Name: Hashable {
    let value: String

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
      for byte in value.utf8 { hasher.combine(byte) }
    }
  }

  private var indices: [Name: Int]?

  func index(
    named name: String,
    library: UnsafePointer<SQLiteLibrary>,
    statement: OpaquePointer
  ) -> Int? {
    if indices == nil {
      var mapping: [Name: Int] = [:]
      let count = Int(library.pointee.columns.count(statement))
      mapping.reserveCapacity(count)
      for index in 0..<count {
        let value =
          library.pointee.columns.name(statement, Int32(index))
          .map(String.init(cString:)) ?? ""
        let key = Name(value: value)
        if mapping[key] == nil { mapping[key] = index }
      }
      indices = mapping
    }
    return indices?[Name(value: name)]
  }
}
