/// A cursor that initializes an owned value from each raw row.
///
/// Created by ``OrbitDatabaseReadTransaction/fetchCursor(_:asRow:cached:)`` or
/// ``OrbitDatabaseWriteTransaction/executeCursor(_:asRow:cached:)``. It supports the same lazy
/// adapters and terminal operations as other ``OrbitDatabaseCursor`` conformances.
public struct OrbitDatabaseRowDecodingCursor<
  Base: OrbitDatabaseRowCursor,
  Value: ConvertibleFromOrbitDatabaseRow
>: OrbitDatabaseCursor, ~Copyable, ~Escapable
where Base: ~Copyable, Base: ~Escapable {
  /// The owned value produced for each row.
  public typealias Element = Value

  @usableFromInline
  internal var base: Base

  @_lifetime(copy base)
  @usableFromInline
  internal init(base: consuming Base) {
    self.base = base
  }

  /// Advances the cursor and initializes the next value, or returns `nil` when exhausted.
  ///
  /// Initialization and statement errors propagate without skipping a row.
  @inlinable
  public mutating func next() throws -> Value? {
    guard let row = try base.next() else { return nil }
    return try Value(orbitDatabaseRow: row)
  }
}
