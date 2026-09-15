/// A table whose one meaningful row has a stable primary key and an in-memory default.
///
/// A conforming table is useful for settings and other document-scoped state that belongs in the
/// database but does not naturally form a collection. ``defaultValue`` serves two purposes: it is
/// the value read before the row has ever been persisted, and its primary key permanently
/// identifies the singleton row.
///
/// Conformance describes which row is the singleton; it cannot prevent other rows from being
/// inserted. A schema that must enforce the invariant should constrain its primary key too.
///
/// ```swift
/// @Table
/// struct Settings: SingleRowTable {
///   let id: Int
///   var notificationsEnabled = true
///
///   static let defaultValue = Settings(id: 0)
/// }
/// ```
public protocol SingleRowTable: PrimaryKeyedTable where QueryOutput == Self {
  /// The value to read when the singleton row has not been persisted yet.
  ///
  /// Its primary key identifies the row every ``SingleRow`` observes and writes.
  static var defaultValue: Self { get }
}

extension SingleRowTable where PrimaryKey.QueryOutput: Equatable {
  /// Finds the singleton in a read transaction, returning ``defaultValue`` when it has not been
  /// persisted yet.
  public static func find(
    in transaction: borrowing SQLiteReadTransaction
  ) throws -> Self {
    try findSingleton(in: transaction)
  }

  /// Finds the singleton in a write transaction, returning ``defaultValue`` when it has not been
  /// persisted yet.
  public static func find(
    in transaction: borrowing SQLiteWriteTransaction
  ) throws -> Self {
    try findSingleton(in: transaction)
  }

  /// Inserts or replaces the singleton in a write transaction.
  ///
  /// - Throws: ``OrbitRowIdentityMismatchError`` when this value does not have
  ///   ``defaultValue``'s primary key, or whatever executing the statement throws.
  public func save(in transaction: borrowing SQLiteWriteTransaction) throws {
    guard primaryKey == Self.defaultValue.primaryKey else {
      throw OrbitRowIdentityMismatchError()
    }
    try transaction.execute(Self.upsert { Self.Draft(self) })
  }

  /// Mutates the latest singleton and saves it in the same write transaction.
  ///
  /// When the row has not been persisted, `update` starts from ``defaultValue``.
  @discardableResult
  public static func update<Result>(
    in transaction: borrowing SQLiteWriteTransaction,
    _ update: (inout Self) throws -> Result
  ) throws -> Result {
    var value = try find(in: transaction)
    let result = try update(&value)
    try value.save(in: transaction)
    return result
  }

  private static func findSingleton<Transaction>(
    in transaction: borrowing Transaction
  ) throws -> Self
  where
    Transaction: OrbitDatabaseReadTransaction, Transaction: ~Copyable, Transaction: ~Escapable
  {
    let statement: Select<Self, Self, ()> = all.selectStar()
    return try transaction.fetchOne(
      statement.find(PrimaryKey(queryOutput: defaultValue.primaryKey))
    ) ?? defaultValue
  }
}

/// Thrown when a value being saved has a different primary key from the row its property observes.
///
/// A mutable row's identity is fixed when its property is created. Rejecting a changed key keeps
/// its read and write sides coherent: a property can never observe one row while writing another.
public struct OrbitRowIdentityMismatchError: Error, Sendable {
  /// Creates the error.
  public init() {}
}

extension OrbitRowIdentityMismatchError: CustomStringConvertible {
  public var description: String {
    "A mutable row cannot save a value whose primary key differs from the row it observes."
  }
}
