/// How a collation orders two values.
///
/// ```swift
/// configuration.registerCollation("length") { lhs, rhs in
///   lhs.count < rhs.count ? .ascending : lhs.count > rhs.count ? .descending : .same
/// }
/// ```
public enum SQLiteCollationOrder: Hashable, Sendable {
  /// The first value sorts before the second.
  case ascending

  /// The two values sort together.
  case same

  /// The first value sorts after the second.
  case descending
}

extension SQLiteConfiguration {
  /// Registers a collating sequence on every connection opened with this configuration.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.registerCollation("length") { lhs, rhs in
  ///   lhs.count < rhs.count ? .ascending : lhs.count > rhs.count ? .descending : .same
  /// }
  /// ```
  ///
  /// SQL then refers to it by name, as in `ORDER BY title COLLATE length`.
  ///
  /// - Parameters:
  ///   - name: The name SQL refers to the collation by.
  ///   - compare: Orders two values, given their UTF-8 bytes, which are only valid during the call.
  ///     It must be consistent: the same two values must always compare the same way.
  public mutating func registerCollation(
    _ name: String,
    _ compare:
      @escaping @Sendable (UnsafeRawBufferPointer, UnsafeRawBufferPointer) -> SQLiteCollationOrder
  ) {
    register(.collations, providedBy: \.collations) { connection in
      orbitInstallCollation(
        name,
        compare: compare,
        on: connection.sqliteConnection,
        library: connection.sqlite
      )
    }
  }
}

typealias SQLiteCollationComparator =
  @Sendable (UnsafeRawBufferPointer, UnsafeRawBufferPointer) -> SQLiteCollationOrder

func orbitInstallCollation(
  _ name: String,
  compare: @escaping SQLiteCollationComparator,
  on connection: OpaquePointer?,
  library: SQLiteLibrary
) -> Int32 {
  let box = Box.retain(compare)
  let code = name.withCString { name in
    library.collations!
      .create(
        connection,
        name,
        SQLiteFunctionFlags.utf8.rawValue,
        box,
        { box, lhsCount, lhs, rhsCount, rhs in
          // A comparator is handed its user data directly, so it is the one callback that needs
          // nothing from the build that called it.
          let compare = Box<SQLiteCollationComparator>.value(in: box)
          switch compare(
            UnsafeRawBufferPointer(start: lhs, count: Int(lhsCount)),
            UnsafeRawBufferPointer(start: rhs, count: Int(rhsCount))
          ) {
          case .ascending: return -1
          case .same: return 0
          case .descending: return 1
          }
        },
        { Box<SQLiteCollationComparator>.release($0) }
      )
  }
  // A registration that fails takes the collation with it, and SQLite only calls the destructor
  // of one that succeeded — unlike `sqlite3_create_function_v2`, which calls it either way.
  if code != SQLiteResultCode.ok.rawValue {
    Box<SQLiteCollationComparator>.release(box)
  }
  return code
}
