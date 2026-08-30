import GRDB

/// A GRDB database that participates in cross-process transaction observation.
public protocol CrossProcessDatabase: Sendable {
  /// The identity used by the cross-process transport.
  var identifier: DatabaseIdentifier { get }

  /// The GRDB writer that owns local access and observation.
  var writer: any DatabaseWriter { get }
}

extension CrossProcessDatabase {
  /// Tells GRDB that another process committed changes to this database.
  ///
  /// This conservatively invalidates the full database so active GRDB observations fetch fresh
  /// values. A future protocol revision can carry table-level regions without changing the
  /// transport boundary.
  public func notifyChangesFromExternalCommit() async throws {
    try await writer.write { database in
      try database.notifyChanges(in: .fullDatabase)
    }
  }
}
