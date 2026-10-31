#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// Provides the date of database transactions, as `Database.transactionDate`.
  public protocol TransactionClock: Sendable {
    /// The current date.
    func now(_ db: Database) throws -> Date
  }

  extension TransactionClock where Self == DefaultTransactionClock {
    /// The clock that returns the current system date.
    public static var `default`: Self { DefaultTransactionClock() }
  }

  extension TransactionClock where Self == CustomTransactionClock {
    /// A clock that returns the result of a function.
    public static func custom(_ now: @escaping @Sendable (Database) throws -> Date) -> Self {
      CustomTransactionClock(now)
    }
  }

  /// The clock that returns the current system date.
  public struct DefaultTransactionClock: TransactionClock {
    public func now(_ db: Database) throws -> Date { Date() }
  }

  /// A clock that returns the result of a function.
  public struct CustomTransactionClock: TransactionClock {
    let now: @Sendable (Database) throws -> Date

    public init(_ now: @escaping @Sendable (Database) throws -> Date) {
      self.now = now
    }

    public func now(_ db: Database) throws -> Date {
      try now(db)
    }
  }

  extension Database {
    /// The date of the current transaction, constant until it ends, or the current date of the
    /// configured clock outside of a transaction.
    public var transactionDate: Date {
      get throws {
        let state = connectionState
        guard isInsideTransaction else {
          state.transactionDate = nil
          return try configuration.transactionClock.now(self)
        }
        if let date = state.transactionDate {
          return try date.get()
        }
        let date = Result { try configuration.transactionClock.now(self) }
        state.transactionDate = date
        return try date.get()
      }
    }
  }

  // MARK: - Regions

  extension DatabaseRegion {
    /// Whether the region is the full database.
    public var isFullDatabase: Bool {
      native.isFullDatabase
    }

    /// Adds another region to this one.
    public mutating func formUnion(_ other: Self) {
      self = union(other)
    }

    /// Restricts this region to its intersection with another one.
    public mutating func formIntersection(_ other: Self) {
      self = intersection(other)
    }
  }

  /// A type-erased `DatabaseRegionConvertible`.
  public struct AnyDatabaseRegionConvertible: DatabaseRegionConvertible {
    let region: @Sendable (Database) throws -> DatabaseRegion

    /// Creates a region from a function.
    public init(_ region: @escaping @Sendable (Database) throws -> DatabaseRegion) {
      self.region = region
    }

    /// Wraps another region.
    public init(_ region: some DatabaseRegionConvertible) {
      self.region = { try region.databaseRegion($0) }
    }

    public func databaseRegion(_ db: Database) throws -> DatabaseRegion {
      try region(db)
    }
  }

  extension DatabaseRegionConvertible where Self == DatabaseRegion {
    /// The region of the full database.
    public static var fullDatabase: Self { DatabaseRegion.fullDatabase }
  }
#endif
