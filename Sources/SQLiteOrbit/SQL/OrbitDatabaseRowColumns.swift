/// Maps a model's property key paths to SQL result-column names.
///
/// ``OrbitRow()`` synthesizes this mapping for stored instance properties, respecting
/// ``OrbitColumn(_:)`` renames. Return `nil` for properties without a result-column mapping,
/// such as computed properties. This protocol is independent of row initialization and
/// describes result columns without requiring table or persistence metadata.
public protocol OrbitDatabaseRowColumns {
  /// The SQL result-column name for a property, or `nil` when it is not mapped.
  static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String?
}
