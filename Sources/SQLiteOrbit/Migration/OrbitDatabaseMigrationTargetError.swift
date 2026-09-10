/// Reported when a migrator cannot migrate a database up to the migration it was given.
///
/// Thrown by ``OrbitDatabaseMigrator/migrate(_:upTo:)`` before anything is written.
///
/// ```swift
/// do {
///   try await migrator.migrate(database, upTo: "Add due dates")
/// } catch let error as OrbitDatabaseMigrationTargetError {
///   print(error)
/// }
/// ```
public struct OrbitDatabaseMigrationTargetError: Error, Hashable, CustomStringConvertible {
  /// Why the target cannot be migrated up to.
  public enum Reason: Hashable, Sendable {
    /// No migration is registered with the target's identifier.
    case unregistered

    /// The database has already applied a migration registered after the target, which migrating
    /// up to the target cannot undo.
    ///
    /// The associated value is the identifier of that later migration.
    case migratedBeyond(String)
  }

  /// The identifier of the migration that was given as the target.
  public let target: String

  /// Why the target cannot be migrated up to.
  public let reason: Reason

  /// Names the target and explains why it cannot be migrated up to.
  public var description: String {
    switch reason {
    case .unregistered:
      """
      No migration named "\(target)" is registered, so the database cannot be migrated up to it.
      """
    case .migratedBeyond(let later):
      """
      The database cannot be migrated up to "\(target)": "\(later)", which is registered after \
      it, has already been applied.
      """
    }
  }
}
