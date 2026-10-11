/// How a database keeps the changes of a transaction until they commit: SQLite's
/// `PRAGMA journal_mode`.
///
/// Set ``SQLiteConfiguration/journalMode`` to have every writable connection a driver opens switch
/// the database to a mode before anything else runs on it.
///
/// ```swift
/// var configuration = SQLiteConfiguration.default
/// configuration.journalMode = .wal
/// let driver = try SQLiteQueue(path: .file(url), configuration: configuration)
/// ```
///
/// The raw value is the name SQLite reports from `PRAGMA journal_mode`. A mode this type has no
/// constant for can be created from its name, which must consist only of ASCII letters.
public struct SQLiteJournalMode: RawRepresentable, Hashable, Sendable {
  /// The mode's name, as `PRAGMA journal_mode` takes and reports it.
  public let rawValue: String

  /// Creates a journal mode from its name.
  ///
  /// - Parameter rawValue: The mode's name, as `PRAGMA journal_mode` takes it.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Deletes the rollback journal at the end of each transaction. SQLite's default.
  public static let delete = Self(rawValue: "delete")

  /// Truncates the rollback journal to zero bytes at the end of each transaction rather than
  /// deleting it.
  public static let truncate = Self(rawValue: "truncate")

  /// Keeps the rollback journal and overwrites its header at the end of each transaction.
  public static let persist = Self(rawValue: "persist")

  /// Keeps the rollback journal in memory, saving disk I/O at the cost of safety: a crash in the
  /// middle of a transaction will likely corrupt the database.
  public static let memory = Self(rawValue: "memory")

  /// Writes changes to a write-ahead log, so that readers and a writer do not block one another.
  ///
  /// This is the mode ``SQLitePool`` runs a database in. It persists in the database file once
  /// set.
  public static let wal = Self(rawValue: "wal")

  /// Keeps no rollback journal at all, so a transaction cannot be rolled back safely.
  public static let off = Self(rawValue: "off")

  /// Turso's multi-version concurrency control, which lets transactions begun with
  /// `BEGIN CONCURRENT` write at the same time.
  ///
  /// Only Turso implements this mode. It is the mode ``TursoPool`` runs a database in. Stock
  /// SQLite does not recognize it and leaves the journal mode unchanged.
  public static let mvcc = Self(rawValue: "mvcc")
}

extension SQLiteJournalMode {
  /// The name as it can be written into `PRAGMA journal_mode`, which takes no bound parameter.
  ///
  /// - Throws: A ``SQLiteError`` with `SQLITE_MISUSE` when the name holds anything but ASCII
  ///   letters.
  func pragmaValue() throws -> String {
    let isName =
      !rawValue.isEmpty
      && rawValue.utf8.allSatisfy { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
    guard isName else {
      throw SQLiteError(
        code: .misuse,
        message: "\"\(rawValue)\" is not a journal mode name"
      )
    }
    return rawValue
  }
}
