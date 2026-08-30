/// The part of a database changed by a committed transaction.
public enum DatabaseChangeRegion: Codable, Hashable, Sendable {
  /// The change may affect any database object.
  case fullDatabase

  /// The change is limited to the named tables.
  case tables(Set<String>)

  /// Returns a region containing everything covered by either region.
  public func union(_ other: Self) -> Self {
    switch (self, other) {
    case (.fullDatabase, _), (_, .fullDatabase):
      return .fullDatabase
    case (.tables(let lhs), .tables(let rhs)):
      return .tables(lhs.union(rhs))
    }
  }
}
