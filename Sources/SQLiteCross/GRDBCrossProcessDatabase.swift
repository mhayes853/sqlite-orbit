#if GRDB
  import GRDB

  extension CrossProcessDatabase where Driver == GRDBDatabaseDriver {
    /// Creates a cross-process database backed by a GRDB database writer.
    public convenience init(
      writer: any DatabaseWriter,
      id: DatabaseIdentifier? = nil
    ) {
      self.init(driver: GRDBDatabaseDriver(writer: writer), id: id)
    }
  }
#endif
