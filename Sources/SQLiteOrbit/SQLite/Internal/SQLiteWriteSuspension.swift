/// Keeps a writer connection from holding SQLite's write lock while its database is suspended.
///
/// iOS ends a process that is suspended while holding a lock on a file in a shared container. It
/// tolerates the read locks of a database in WAL mode, which is what lets a suspended database keep
/// reading, but not the write lock. So a suspension interrupts the statement running on the writer
/// and refuses, at the step that would run it, every statement that could take or keep that lock:
/// anything that writes, and anything at all inside a transaction except the rollback that ends it.
/// A write is therefore rolled back rather than committed, even when its body ignores the refusal.
///
/// The refusal is made where the connection steps statements, so it covers the statements a
/// transaction runs, those the connection runs on its own behalf, and those run through the raw
/// connection alike.
final class SQLiteWriteSuspension: Sendable {
  private struct State {
    var isSuspended = false
    // Set only while an access runs, so that a suspension cannot interrupt a later one.
    var interrupt: (@Sendable () -> Void)?
    var hasRefusedAccess = false
  }

  let databaseIdentifier: OrbitDatabaseIdentifier
  private let state = Lock(State())

  init(databaseIdentifier: OrbitDatabaseIdentifier) {
    self.databaseIdentifier = databaseIdentifier
  }

  var isSuspended: Bool {
    state.withLock { $0.isSuspended }
  }

  func suspend() {
    state.withLock { state in
      guard !state.isSuspended else { return }
      state.isSuspended = true
      // Interrupting under the lock keeps an access from ending, and the next from beginning,
      // between reading the interrupt and calling it.
      state.interrupt?()
    }
  }

  func resume() {
    state.withLock { $0.isSuspended = false }
  }

  /// Runs one access on the connection, reporting a failure the suspension caused as
  /// ``OrbitDatabaseSuspendedError``.
  ///
  /// A statement the suspension refused or interrupted fails with `SQLITE_INTERRUPT`, which is
  /// replaced here. Any other failure, including one the body throws after catching a refusal, is
  /// left as it is.
  func trackingAccess<Result>(
    interrupt: @escaping @Sendable () -> Void,
    _ body: () throws -> Result
  ) throws -> Result {
    state.withLock { state in
      state.interrupt = interrupt
      state.hasRefusedAccess = false
    }
    do {
      let value = try body()
      state.withLock { $0.interrupt = nil }
      return value
    } catch {
      let hasRefusedAccess = state.withLock { state in
        state.interrupt = nil
        return state.hasRefusedAccess
      }
      if hasRefusedAccess, let error = error as? SQLiteError, error.isInterruption {
        throw OrbitDatabaseSuspendedError(databaseIdentifier: databaseIdentifier)
      }
      throw error
    }
  }

  /// Returns the step entry point for a writer connection opened through `library`, refusing the
  /// statements a suspension forbids.
  func step(
    of library: SQLiteLibrary,
    on connection: OpaquePointer
  ) -> @Sendable (OpaquePointer?) -> Int32 {
    let step = library.statements.execution.step
    let isReadOnly = library.statements.inspection.isReadOnly
    let sql = library.statements.inspection.sql
    let isAutocommit = library.connections.isAutocommit
    // An address rather than a pointer, so that the closure can be shared. The connection outlives
    // it, since the handle that owns this entry point closes the connection.
    let address = UInt(bitPattern: connection)
    return { [self] statement in
      let isRefused = state.withLock { state in
        guard state.isSuspended else { return false }
        let connection = OpaquePointer(bitPattern: address)
        // In WAL mode a statement that only reads takes no lock iOS objects to, but inside a
        // transaction on the writer the write lock is already held, and only a rollback lets go of
        // it without committing.
        let isAdmitted =
          isAutocommit(connection) != 0
          ? isReadOnly(statement) != 0
          : Self.isRollback(sql(statement))
        if !isAdmitted { state.hasRefusedAccess = true }
        return !isAdmitted
      }
      if isRefused { return SQLiteResultCode.interrupt.rawValue }
      let code = step(statement)
      if code & 0xff == SQLiteResultCode.interrupt.rawValue {
        // The suspension may have interrupted a statement that was already running.
        state.withLock { state in
          if state.isSuspended { state.hasRefusedAccess = true }
        }
      }
      return code
    }
  }

  // Whether `sql` rolls a transaction back, which is the one statement a suspension must let run
  // inside one. `ROLLBACK TO` a savepoint is admitted too; it leaves the transaction open, so the
  // next statement is refused all the same.
  private static func isRollback(_ sql: UnsafePointer<CChar>?) -> Bool {
    guard var character = sql else { return false }
    while character.pointee == 0x20 || (0x09...0x0D).contains(character.pointee) {
      character += 1
    }
    for expected in "ROLLBACK".utf8 {
      // ASCII letters differ from their capitals only in bit 5.
      guard UInt8(bitPattern: character.pointee) & ~0x20 == expected else { return false }
      character += 1
    }
    return true
  }
}
