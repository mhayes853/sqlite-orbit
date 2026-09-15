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
