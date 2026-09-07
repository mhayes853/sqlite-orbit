/// A description of how to read one value from a database.
///
/// A request is what ``Fetch`` observes. Everything it reads comes from one transaction, so a
/// value assembled from several queries is always internally consistent, and the property refetches
/// whenever a committed write touches any region the request read:
///
/// ```swift
/// struct RemindersOverview: OrbitFetchKeyRequest {
///   struct Value: Sendable {
///     var incompleteCount = 0
///     var newest: [Reminder] = []
///   }
///
///   func fetch(_ transaction: borrowing SQLiteReadTransaction) throws -> Value {
///     try Value(
///       incompleteCount: transaction.fetchCount(Reminder.where { !$0.isCompleted }),
///       newest: transaction.fetchAll(Reminder.order { $0.createdAt.desc() }.limit(10))
///     )
///   }
/// }
///
/// @Fetch(RemindersOverview()) var overview = RemindersOverview.Value()
/// ```
///
/// A request is `Hashable` so that a property can tell one request from another. Two requests that
/// compare equal describe the same read, which is how a SwiftUI view that is re-created with an
/// unchanged query keeps observing rather than starting over.
public protocol OrbitFetchKeyRequest<Value>: Hashable, Sendable {
  /// The value the request reads.
  associatedtype Value: Sendable

  /// Reads the value from a transaction.
  ///
  /// - Parameter transaction: The read transaction to read from. It cannot escape the call.
  /// - Returns: The value the request describes.
  /// - Throws: Whatever reading throws.
  func fetch(_ transaction: borrowing SQLiteReadTransaction) throws -> Value
}
