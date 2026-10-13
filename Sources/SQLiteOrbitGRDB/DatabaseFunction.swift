#if canImport(Foundation) && canImport(Dispatch)
  import Foundation
  @_spi(GRDB) import SQLiteOrbit

  public struct DatabaseFunction: Sendable {
    public let name: String
    public let argumentCount: Int?
    public let isPure: Bool
    let body: @Sendable ([DatabaseValue]) throws -> (any DatabaseValueConvertible)?
    public init(
      _ name: String,
      argumentCount: Int? = nil,
      pure: Bool = false,
      function: @escaping @Sendable ([DatabaseValue]) throws -> (any DatabaseValueConvertible)?
    ) {
      self.name = name
      self.argumentCount = argumentCount
      isPure = pure
      body = function
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
            try connection.registerFunction(
              function.name,
              argumentCount: function.argumentCount,
              flags: function.isPure ? [.deterministic] : []
            ) { arguments in
              let values = (0..<arguments.count).map { DatabaseValue(arguments[$0]) }
              return try function.body(values)?.databaseValue.orbitValue ?? .null
            }
          }
        }
      } catch { preconditionFailure(String(describing: error)) }
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
      } catch { preconditionFailure(String(describing: error)) }
    }
  }

#endif
