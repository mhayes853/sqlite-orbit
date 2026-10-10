/// A cursor's column reading, shared by its borrowed rows: the library's column operations and a
/// lazily prepared mapping from names to positions.
///
/// The operations are copied here once per cursor. They are C function pointers, so the copy is
/// eight words, and a row calls them from the reader it already holds rather than through the
/// library pointer as well, which measures a fraction of a percent fewer instructions.
///
/// The name mapping is prepared on the first named lookup, after SQLite has stepped and had the
/// chance to recompile its statement. A new cursor always gets a new mapping, even for a cached
/// statement.
@usableFromInline
final class SQLiteRowColumnReader {
  @usableFromInline
  let columns: SQLiteLibrary.Columns

  // A column's name as its byte count and its first eight bytes, which is all of most names,
  // packed into an integer, so most comparisons are two integer comparisons. Swift String
  // equality normalizes Unicode, and SQL result names instead match their exact bytes.
  private struct Name {
    var count: Int
    var prefix: UInt64
    // Where the bytes past the first eight start in `nameSuffixes`.
    var suffixStart: Int
    // Whether no earlier column has the same name. Only the first is ever found by its name.
    var isFirst: Bool
  }

  // Lookups run on the cursor's thread, between steps, so they need no exclusivity checks.
  @exclusivity(unchecked) private var names: ContiguousArray<Name> = []
  @exclusivity(unchecked) private var nameSuffixes: ContiguousArray<UInt8> = []
  @exclusivity(unchecked) private var hasNames = false

  // Where the column after the last one found is. A row is usually read in the order of its
  // columns, so that is where the next lookup is most likely to be.
  @exclusivity(unchecked) private var nextIndex = 0

  init(columns: SQLiteLibrary.Columns) {
    self.columns = columns
  }

  // MARK: - Values

  // Each value is read in the storage class SQLite reports, so reading it never converts it, and
  // text or a blob is asked for before its size, which is the order SQLite documents as safe:
  // reading the size can convert the value, and a pointer taken before that conversion is the one
  // it invalidates.

  // The value of a column in the storage class SQLite holds it in.
  @inlinable
  func value(_ statement: OpaquePointer, at column: Int32) -> OrbitDatabaseValue {
    switch SQLiteColumnType(rawValue: columns.type(statement, column)) {
    case .integer: .integer(columns.int64(statement, column))
    case .float: .real(columns.double(statement, column))
    case .text: .text(text(statement, at: column))
    case .blob: .blob(blob(statement, at: column))
    default: .null
    }
  }

  // A column's text, which SQLite may hold with NUL bytes in it, so it is never read as a C
  // string.
  @inlinable
  func text(_ statement: OpaquePointer, at column: Int32) -> String {
    withUTF8(statement, at: column) { String(decoding: $0, as: UTF8.self) }
  }

  // A column's text as bytes that are only valid during `body`.
  @inlinable
  func withUTF8<Result>(
    _ statement: OpaquePointer,
    at column: Int32,
    _ body: (UnsafeBufferPointer<UInt8>) throws -> Result
  ) rethrows -> Result {
    guard let text = columns.text(statement, column) else {
      return try body(UnsafeBufferPointer(start: nil, count: 0))
    }
    let byteCount = Int(columns.byteCount(statement, column))
    return try body(UnsafeBufferPointer(start: text, count: max(byteCount, 0)))
  }

  // A column's bytes. A zero-length blob has no buffer to point at.
  @inlinable
  func blob(_ statement: OpaquePointer, at column: Int32) -> [UInt8] {
    guard let bytes = columns.blob(statement, column) else { return [] }
    let byteCount = Int(columns.byteCount(statement, column))
    guard byteCount > 0 else { return [] }
    return [UInt8](UnsafeRawBufferPointer(start: bytes, count: byteCount))
  }

  // MARK: - Names

  // The position of the first column whose name has exactly these UTF-8 bytes.
  func index(named name: String, statement: OpaquePointer) -> Int? {
    if !hasNames { prepareNames(statement) }
    let found =
      name.utf8.withContiguousStorageIfAvailable(index(of:))
      ?? ContiguousArray(name.utf8).withUnsafeBufferPointer(index(of:))
    if let found { nextIndex = found &+ 1 }
    return found
  }

  private func index(of name: UnsafeBufferPointer<UInt8>) -> Int? {
    let prefix = Self.prefix(of: name)
    return names.withUnsafeBufferPointer { names in
      func matches(_ index: Int) -> Bool {
        let entry = names[index]
        guard entry.prefix == prefix, entry.count == name.count, entry.isFirst else {
          return false
        }
        guard name.count > 8 else { return true }
        return nameSuffixes.withUnsafeBufferPointer { suffixes in
          name[8...].elementsEqual(suffixes[entry.suffixStart..<entry.suffixStart + name.count - 8])
        }
      }
      if nextIndex < names.count, matches(nextIndex) { return nextIndex }
      for index in names.indices where matches(index) { return index }
      return nil
    }
  }

  private static func prefix(of bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
    var prefix: UInt64 = 0
    for index in 0..<min(bytes.count, 8) {
      prefix |= UInt64(bytes[index]) << (8 * index)
    }
    return prefix
  }

  private func prepareNames(_ statement: OpaquePointer) {
    let count = Int(columns.count(statement))
    names.reserveCapacity(count)
    var seen: Set<[UInt8]> = []
    for index in 0..<count {
      let name = columns.name(statement, Int32(index)).map(String.init(cString:)) ?? ""
      let bytes = Array(name.utf8)
      names.append(
        Name(
          count: bytes.count,
          prefix: bytes.withUnsafeBufferPointer(Self.prefix(of:)),
          suffixStart: nameSuffixes.count,
          isFirst: seen.insert(bytes).inserted
        )
      )
      nameSuffixes += bytes.dropFirst(8)
    }
    hasNames = true
  }
}
