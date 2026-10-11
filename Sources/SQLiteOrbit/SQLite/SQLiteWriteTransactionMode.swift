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

  var beginSQL: String {
    switch self {
    case .deferred: "BEGIN DEFERRED TRANSACTION"
    case .immediate: "BEGIN IMMEDIATE TRANSACTION"
    case .exclusive: "BEGIN EXCLUSIVE TRANSACTION"
    case .concurrent: "BEGIN CONCURRENT TRANSACTION"
    }
  }
}
