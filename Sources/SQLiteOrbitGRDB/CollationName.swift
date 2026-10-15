#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  extension Database {
    public struct CollationName: RawRepresentable, Hashable, Sendable {
      public let rawValue: String

      public init(rawValue: String) {
        self.rawValue = rawValue
      }

      public static let binary = Self(rawValue: "BINARY")
      public static let nocase = Self(rawValue: "NOCASE")
      public static let rtrim = Self(rawValue: "RTRIM")
    }

    public func reindex(collation: CollationName) throws {
      try execute(sql: "REINDEX " + quoted(collation.rawValue))
    }
  }

  extension SQLExpressible {
    public func collating(_ collation: Database.CollationName) -> SQLExpression {
      collating(collation.rawValue)
    }

    public func collating(_ collation: DatabaseCollation) -> SQLExpression {
      collating(collation.name)
    }
  }

  extension ColumnDefinition {
    @discardableResult
    public func collate(_ collation: Database.CollationName) -> Self {
      collate(collation.rawValue)
    }
  }
#endif
