#if canImport(Foundation) && canImport(Dispatch)
  import SQLiteOrbit

  extension Database {
    public enum CheckpointMode: Sendable {
      case passive, full, restart, truncate

      var native: SQLiteWALCheckpointMode {
        switch self {
        case .passive: .passive
        case .full: .full
        case .restart: .restart
        case .truncate: .truncate
        }
      }
    }

    @discardableResult
    public func checkpoint(_ kind: CheckpointMode = .passive, on dbName: String? = "main") throws
      -> (walFrameCount: Int, checkpointedFrameCount: Int)
    {
      let result = try translate {
        try access.checkpoint(kind.native, schema: dbName.map(SQLiteSchemaName.init(rawValue:)))
      }
      return (result.logFrameCount, result.checkpointedFrameCount)
    }
  }
#endif
