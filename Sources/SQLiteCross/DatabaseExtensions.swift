public import StructuredQueriesSQLite

/// Collating sequences and functions, implemented in Swift, to install on database connections.
///
/// A connection only knows the collations and functions installed on it. Pooled drivers open
/// connections on demand, so these are collected up front and installed on each new connection
/// rather than added to one connection after the fact.
public struct DatabaseExtensions: Sendable {
  /// The collating sequences to install.
  public private(set) var collations: [any DatabaseCollation & Sendable] = []

  /// The scalar functions to install.
  public private(set) var scalarFunctions: [any ScalarDatabaseFunction & Sendable] = []

  /// The aggregate functions to install.
  public private(set) var aggregateFunctions: [any AggregateDatabaseFunction & Sendable] = []

  public init() {}

  /// Adds a collating sequence, as defined by the `@DatabaseCollation` macro.
  public mutating func add(collation: some DatabaseCollation & Sendable) {
    collations.append(collation)
  }

  /// Adds a scalar function, as defined by the `@DatabaseFunction` macro.
  public mutating func add(function: some ScalarDatabaseFunction & Sendable) {
    scalarFunctions.append(function)
  }

  /// Adds an aggregate function, as defined by the `@DatabaseFunction` macro.
  public mutating func add(function: some AggregateDatabaseFunction & Sendable) {
    aggregateFunctions.append(function)
  }

  /// Whether there is nothing to install.
  public var isEmpty: Bool {
    collations.isEmpty && scalarFunctions.isEmpty && aggregateFunctions.isEmpty
  }
}
