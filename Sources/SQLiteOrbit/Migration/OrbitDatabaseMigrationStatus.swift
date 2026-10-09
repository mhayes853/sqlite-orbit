/// A snapshot of registered migrations and the identifiers a database has already applied.
///
/// Obtain a snapshot with ``OrbitDatabaseMigrator/status(in:)`` or construct one from a migration
/// history supplied by another database implementation. Unknown applied identifiers are retained.
public struct OrbitDatabaseMigrationStatus: Hashable, Sendable {
  /// Registered identifiers in migration order.
  public let registeredIdentifiers: [String]

  /// Every applied identifier, including identifiers absent from this registration history.
  public let appliedIdentifiers: Set<String>

  /// Creates a snapshot without accessing a database.
  public init(registeredIdentifiers: [String], appliedIdentifiers: Set<String>) {
    self.registeredIdentifiers = registeredIdentifiers
    self.appliedIdentifiers = appliedIdentifiers
  }

  /// Applied registered migrations in registration order.
  public var appliedMigrations: [String] {
    registeredIdentifiers.filter(appliedIdentifiers.contains)
  }

  /// Registered migrations not yet applied, in registration order.
  public var pendingMigrations: [String] {
    registeredIdentifiers.filter { !appliedIdentifiers.contains($0) }
  }

  /// The contiguous prefix of registered migrations that have all been applied.
  ///
  /// A migration applied after an unapplied migration appears in ``appliedMigrations``, but is
  /// excluded here until that gap is filled.
  public var completedMigrations: [String] {
    Array(registeredIdentifiers.prefix(while: appliedIdentifiers.contains))
  }

  /// Applied identifiers this registration history does not recognize.
  public var unrecognizedIdentifiers: Set<String> {
    appliedIdentifiers.subtracting(registeredIdentifiers)
  }

  /// Whether every registered migration has been applied, regardless of unknown identifiers.
  ///
  /// A snapshot with no registered migrations is complete.
  public var isComplete: Bool {
    registeredIdentifiers.allSatisfy(appliedIdentifiers.contains)
  }

  /// Whether an applied migration is absent from the registration history.
  public var isSuperseded: Bool {
    !appliedIdentifiers.isSubset(of: registeredIdentifiers)
  }
}
