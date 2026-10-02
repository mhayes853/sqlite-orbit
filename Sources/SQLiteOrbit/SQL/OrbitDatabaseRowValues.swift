/// Typed, possibly incomplete values for encoding a record or preparing an insertion.
///
/// Dynamic members use the property's exact Swift type wrapped in an optional. Outer `nil` means
/// omission. For an optional property, `.some(nil)` explicitly writes SQL NULL. Use ``set(_:to:)``
/// for immediate errors and ``unset(_:)`` to clearly express omission.
///
/// ```swift
/// var values = OrbitDatabaseRowValues<Reminder>()
/// values.title = "Buy milk"
/// values.notes = .some(nil)
/// let title: String? = values.title
/// ```
///
/// Assignment retains its original Swift value and conversion result. Dynamic setters retain
/// errors until execution; replacing or unsetting the failing entry clears that error. Copies
/// have independent entries, although any reference values retain their normal Swift semantics.
@dynamicMemberLookup
public struct OrbitDatabaseRowValues<Record: ConvertibleToOrbitDatabaseRow> {
  private struct Entry {
    var original: Any
    var encoded: Result<OrbitDatabaseValue, any Error>
  }

  private var entries: [PartialKeyPath<Record>: Entry] = [:]

  /// Creates values with every column omitted.
  public init() {}

  /// Reads or assigns a typed property. An outer `nil` removes the column.
  ///
  /// Reads also work for values that can be encoded but cannot be decoded. A failed assignment
  /// remains readable and present; its error is reported before any SQL is executed.
  public subscript<Value: ConvertibleToOrbitDatabaseValue>(
    dynamicMember column: KeyPath<Record, Value>
  ) -> Value? {
    get {
      guard let entry = entries[column] else { return nil }
      return entry.original as? Value
    }
    set {
      guard let value = newValue else {
        unset(column)
        return
      }
      entries[column] = Entry(
        original: value,
        encoded: Result { try Self.encode(value, column: column) }
      )
    }
  }

  /// Assigns a value, reporting unsupported columns or conversion failures immediately.
  ///
  /// A failing call leaves any previous value unchanged. Passing `nil` for an optional property
  /// writes SQL NULL rather than omitting the column.
  public mutating func set<Value: ConvertibleToOrbitDatabaseValue>(
    _ column: KeyPath<Record, Value>,
    to value: Value
  ) throws {
    let encoded = try Self.encode(value, column: column)
    entries[column] = Entry(original: value, encoded: .success(encoded))
  }

  /// Removes a column and any deferred error associated with it.
  public mutating func unset(_ column: PartialKeyPath<Record>) {
    entries.removeValue(forKey: column)
  }

  /// Whether a column has been assigned, including an explicit NULL or a failing assignment.
  public func contains(_ column: PartialKeyPath<Record>) -> Bool {
    entries[column] != nil
  }

  private static func encode<Value: ConvertibleToOrbitDatabaseValue>(
    _ value: Value,
    column: KeyPath<Record, Value>
  ) throws -> OrbitDatabaseValue {
    guard Record.orbitColumnName(for: column) != nil else {
      throw OrbitDatabaseRowPersistenceError.unknownColumn
    }
    return try value.orbitDatabaseValue()
  }

  // Sort by exact column bytes so assignment order cannot change the prepared SQL's shape.
  func encodedColumns() throws -> [(name: String, value: OrbitDatabaseValue)] {
    var columns: [(name: String, value: OrbitDatabaseValue)] = []
    for (keyPath, entry) in entries {
      let value = try entry.encoded.get()
      guard let name = Record.orbitColumnName(for: keyPath) else {
        throw OrbitDatabaseRowPersistenceError.unknownColumn
      }
      if columns.contains(where: { $0.name.utf8.elementsEqual(name.utf8) }) {
        throw OrbitDatabaseRowPersistenceError.duplicateColumn(name)
      }
      columns.append((name, value))
    }
    return columns.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
  }
}
