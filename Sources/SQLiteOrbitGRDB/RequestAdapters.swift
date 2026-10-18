#if canImport(Foundation) && canImport(Dispatch)
  /// A statement with bound arguments and an optional row adapter.
  public struct PreparedRequest {
    public var statement: Statement
    public var adapter: (any RowAdapter)?
  }

  extension FetchRequest {
    /// Prepares the SQL returned by `sql(in:)`. Custom requests can override this to attach adapters.
    public func makePreparedRequest(
      _ db: Database,
      forSingleResult singleResult: Bool = false
    ) throws -> PreparedRequest {
      let literal = try sql(in: db)
      let statement =
        try cached
        ? db.cachedStatement(literal: literal) : db.makeStatement(literal: literal)
      return PreparedRequest(statement: statement, adapter: nil)
    }

    /// Adapts fetched rows after any adapter already carried by this request.
    public func adapted(
      _ adapter: @escaping @Sendable (Database) throws -> any RowAdapter
    ) -> AdaptedFetchRequest<Self> {
      AdaptedFetchRequest(base: self, adapter: adapter)
    }
  }

  /// A request that preserves its base SQL and builds a row adapter during database access.
  public struct AdaptedFetchRequest<Base: FetchRequest>: FetchRequest {
    public typealias RowDecoder = Base.RowDecoder
    let base: Base
    let adapter: @Sendable (Database) throws -> any RowAdapter

    public var cached: Bool { base.cached }

    public func sql(in db: Database) throws -> SQL {
      try base.sql(in: db)
    }

    public func makePreparedRequest(
      _ db: Database,
      forSingleResult singleResult: Bool = false
    ) throws -> PreparedRequest {
      var request = try base.makePreparedRequest(db, forSingleResult: singleResult)
      let next = try adapter(db)
      if let first = request.adapter {
        request.adapter = ChainedAdapter(first: first, second: next)
      } else {
        request.adapter = next
      }
      return request
    }
  }

  extension AdaptedFetchRequest: Sendable where Base: Sendable {}

  extension AdaptedFetchRequest: DatabaseRegionConvertible where Base: DatabaseRegionConvertible {
    public func databaseRegion(_ db: Database) throws -> DatabaseRegion {
      try base.databaseRegion(db)
    }
  }
#endif
