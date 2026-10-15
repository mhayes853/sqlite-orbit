#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  import SQLiteOrbit

  public protocol DatabaseAggregate: SendableMetatype {
    init()

    mutating func step(_ dbValues: [DatabaseValue]) throws

    func finalize() throws -> (any DatabaseValueConvertible)?
  }

  private struct AggregateBridge<Aggregate: DatabaseAggregate>: SQLiteAggregateAccumulator {
    var aggregate = Aggregate()

    mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
      try aggregate.step((0..<arguments.count).map { DatabaseValue(arguments[$0]) })
    }

    func finish() throws -> OrbitDatabaseValue {
      try aggregate.finalize()?.databaseValue.orbitValue ?? .null
    }
  }

  public struct DatabaseFunction: Sendable {
    public let name: String
    public let argumentCount: Int?
    public let isPure: Bool

    let install: @Sendable (borrowing SQLiteConnectionAccess) throws -> Void

    public init(
      _ name: String,
      argumentCount: Int? = nil,
      pure: Bool = false,
      function: @escaping @Sendable ([DatabaseValue]) throws -> (any DatabaseValueConvertible)?
    ) {
      self.name = name
      self.argumentCount = argumentCount
      isPure = pure
      install = { connection in
        try connection.registerFunction(
          name,
          argumentCount: argumentCount,
          flags: pure ? [.deterministic] : []
        ) { arguments in
          let values = (0..<arguments.count).map { DatabaseValue(arguments[$0]) }
          return try function(values)?.databaseValue.orbitValue ?? .null
        }
      }
    }

    public init<Aggregate: DatabaseAggregate>(
      _ name: String,
      argumentCount: Int? = nil,
      pure: Bool = false,
      aggregate: Aggregate.Type
    ) {
      self.name = name
      self.argumentCount = argumentCount
      isPure = pure
      install = { connection in
        try connection.registerAggregateFunction(
          name,
          argumentCount: argumentCount,
          flags: pure ? [.deterministic] : [],
          AggregateBridge<Aggregate>()
        )
      }
    }

    public func callAsFunction(_ arguments: any SQLExpressible...) -> SQLExpression {
      SQLExpression(
        SQL(sql: quoted(name) + "(")
          + joined(arguments.map { $0.sqlExpression.literal }, separator: ", ") + SQL(sql: ")")
      )
    }
  }

  public struct DatabaseCollation: Sendable {
    public let name: String
    let compare: @Sendable (String, String) -> ComparisonResult

    public init(_ name: String, function: @escaping @Sendable (String, String) -> ComparisonResult)
    {
      self.name = name
      compare = function
    }
  }

  extension Database {
    public func add(function: DatabaseFunction) {
      do {
        try translate {
          try access.withConnectionAccess { connection in
            try function.install(connection)
          }
        }
      } catch {
        preconditionFailure(String(describing: error))
      }
    }

    public func add(collation: DatabaseCollation) {
      do {
        try translate {
          try access.withConnectionAccess { connection in
            try connection.registerCollation(collation.name) { lhs, rhs in
              switch collation.compare(
                String(decoding: lhs, as: UTF8.self),
                String(decoding: rhs, as: UTF8.self)
              ) {
              case .orderedAscending: .ascending
              case .orderedSame: .same
              case .orderedDescending: .descending
              }
            }
          }
        }
      } catch {
        preconditionFailure(String(describing: error))
      }
    }
  }

#endif
