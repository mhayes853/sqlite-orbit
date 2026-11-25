/// How a write transaction acquires its initial locks.
public enum SQLiteWriteTransactionMode: Equatable, Sendable {
  /// Defers acquiring the write lock until the transaction first writes.
  case deferred
  /// Acquires the write lock when the transaction begins.
  case immediate
  /// Acquires an exclusive lock where supported by the journal mode.
  case exclusive
  /// Uses `BEGIN CONCURRENT`, requiring a SQLite build that supports it.
  case concurrent

  var beginStatement: SQLiteControlStatement {
    switch self {
    case .deferred: .beginDeferred
    case .immediate: .beginImmediate
    case .exclusive: .beginExclusive
    case .concurrent: .beginConcurrent
    }
  }
}
