/// How hard a checkpoint tries to move a write-ahead log back into the database file.
///
/// SQLite checkpoints on its own once the log passes a threshold, but only passively, so a log
/// can grow without bound while readers keep old frames in use. An explicit checkpoint is how an
/// app bounds it, for example before backing up the file or on going to the background.
///
/// ```swift
/// try await database.writeWithoutTransaction { connection in
///   try connection.checkpoint(.truncate)
/// }
/// ```
public enum SQLiteWALCheckpointMode: Hashable, Sendable {
  /// Moves as many frames as it can without waiting for any reader or writer.
  ///
  /// This never reports `SQLITE_BUSY`, and may leave frames behind that a reader still needs.
  case passive

  /// Waits for writers, then for readers of older frames, until the whole log has been moved into
  /// the database file.
  case full

  /// Does what ``full`` does, then waits for readers to finish with the log, so the next writer
  /// starts it over from the beginning.
  case restart

  /// Does what ``restart`` does, then truncates the log file to zero bytes.
  case truncate

  /// SQLite's `SQLITE_CHECKPOINT_*` constant for the mode.
  var rawValue: Int32 {
    switch self {
    case .passive: 0
    case .full: 1
    case .restart: 2
    case .truncate: 3
    }
  }
}

/// What a checkpoint found in the write-ahead log and how much of it it moved.
///
/// Both counts describe the log as the checkpoint left it, so one that moved every frame reports
/// them equal and one that left frames behind for a reader reports fewer checkpointed than logged.
/// A ``SQLiteWALCheckpointMode/truncate`` checkpoint that succeeds empties the log, so it reports
/// `0` for both: what it moved is gone along with the log.
///
/// Both counts are `-1` when the database is not in WAL mode, which is how SQLite answers a
/// checkpoint of a database whose journal is a rollback journal or lives in memory: there is no
/// log, so there is nothing to move and the checkpoint succeeds having done nothing.
public struct SQLiteWALCheckpointResult: Hashable, Sendable {
  /// How many frames the write-ahead log held, or `-1` when the database is not in WAL mode.
  public var logFrameCount: Int

  /// How many of those frames are now in the database file, or `-1` when the database is not in
  /// WAL mode.
  public var checkpointedFrameCount: Int

  /// Creates a checkpoint result.
  ///
  /// - Parameters:
  ///   - logFrameCount: How many frames the write-ahead log held.
  ///   - checkpointedFrameCount: How many of those frames are now in the database file.
  public init(logFrameCount: Int, checkpointedFrameCount: Int) {
    self.logFrameCount = logFrameCount
    self.checkpointedFrameCount = checkpointedFrameCount
  }
}
