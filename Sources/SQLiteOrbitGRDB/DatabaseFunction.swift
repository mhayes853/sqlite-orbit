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
    // SQLite still finalizes a group after a failed step; GRDB does not call `finalize` then.
    var stepError: (any Error)?

    mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
      guard stepError == nil else { return }
      do {
        try aggregate.step((0..<arguments.count).map { DatabaseValue(arguments[$0]) })
      } catch {
        stepError = error
        throw reportedFunctionError(error)
      }
    }

    func finish() throws -> OrbitDatabaseValue {
      if let stepError {
        throw reportedFunctionError(stepError)
      }
      do {
        return try aggregate.finalize()?.databaseValue.orbitValue ?? .null
      } catch {
        throw reportedFunctionError(error)
      }
    }
  }

  // SQLite receives the description of a thrown error as its message. A DatabaseError reports
  // only its message, and its code is recovered when the statement fails.
  private struct FunctionErrorMessage: Error, CustomStringConvertible {
    let description: String
  }

  private func reportedFunctionError(_ error: any Error) -> any Error {
    guard let error = error as? DatabaseError else {
      return error
    }
    FunctionErrorSlot.store(error)
    return FunctionErrorMessage(description: error.reportedMessage)
  }

  public struct DatabaseFunction: Identifiable, Sendable {
    /// Identifies a function by name and argument count, as SQLite does.
    public struct ID: Hashable, Sendable {
      let name: String
      let nArg: Int32
    }

    public let name: String
    public let argumentCount: Int?
    public let isPure: Bool

    /// The identifier of the SQL function.
    public var id: ID { ID(name: name, nArg: argumentCount.map(Int32.init) ?? -1) }

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
          do {
            return try function(values)?.databaseValue.orbitValue ?? .null
          } catch {
            throw reportedFunctionError(error)
          }
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
      .function(name, arguments.map(\.sqlExpression), isPure: isPure)
    }
  }

  public struct DatabaseCollation: Identifiable, Sendable {
    /// Identifies a collation by its case-insensitive name.
    public struct ID: Hashable, Sendable {
      var name: String

      public func hash(into hasher: inout Hasher) {
        hasher.combine(name.lowercased())
      }

      public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame
      }
    }

    public let name: String
    let compare: @Sendable (String, String) -> ComparisonResult

    /// The identifier of the collation.
    public var id: ID { ID(name: name) }

    func install(_ connection: borrowing SQLiteConnectionAccess) throws {
      let compare = compare
      try connection.registerCollation(name) { lhs, rhs in
        switch compare(String(decoding: lhs, as: UTF8.self), String(decoding: rhs, as: UTF8.self)) {
        case .orderedAscending: .ascending
        case .orderedSame: .same
        case .orderedDescending: .descending
        }
      }
    }

    public init(_ name: String, function: @escaping @Sendable (String, String) -> ComparisonResult)
    {
      self.name = name
      compare = function
    }
  }

  extension DatabaseFunction {
    /// `swiftCapitalizedString(s)`, installed on every connection.
    public static let capitalize = stringFunction("swiftCapitalizedString") { $0.capitalized }
    /// `swiftLowercaseString(s)`, installed on every connection.
    public static let lowercase = stringFunction("swiftLowercaseString") { $0.lowercased() }
    /// `swiftUppercaseString(s)`, installed on every connection.
    public static let uppercase = stringFunction("swiftUppercaseString") { $0.uppercased() }
    /// `swiftLocalizedCapitalizedString(s)`, installed on every connection.
    public static let localizedCapitalize = stringFunction("swiftLocalizedCapitalizedString") {
      $0.localizedCapitalized
    }
    /// `swiftLocalizedLowercaseString(s)`, installed on every connection.
    public static let localizedLowercase = stringFunction("swiftLocalizedLowercaseString") {
      $0.localizedLowercase
    }
    /// `swiftLocalizedUppercaseString(s)`, installed on every connection.
    public static let localizedUppercase = stringFunction("swiftLocalizedUppercaseString") {
      $0.localizedUppercase
    }

    private static func stringFunction(
      _ name: String,
      _ transform: @escaping @Sendable (String) -> String
    ) -> Self {
      DatabaseFunction(name, argumentCount: 1, pure: true) { values in
        String.fromDatabaseValue(values[0]).map(transform)
      }
    }
  }

  extension DatabaseCollation {
    /// The `swiftCompare` collation, which compares with Swift's `<`.
    public static let unicodeCompare = DatabaseCollation("swiftCompare") { lhs, rhs in
      lhs < rhs ? .orderedAscending : (lhs == rhs ? .orderedSame : .orderedDescending)
    }
    /// The `swiftCaseInsensitiveCompare` collation.
    public static let caseInsensitiveCompare = DatabaseCollation("swiftCaseInsensitiveCompare") {
      $0.caseInsensitiveCompare($1)
    }
    /// The `swiftLocalizedCaseInsensitiveCompare` collation.
    public static let localizedCaseInsensitiveCompare = DatabaseCollation(
      "swiftLocalizedCaseInsensitiveCompare"
    ) { $0.localizedCaseInsensitiveCompare($1) }
    /// The `swiftLocalizedCompare` collation.
    public static let localizedCompare = DatabaseCollation("swiftLocalizedCompare") {
      $0.localizedCompare($1)
    }
    /// The `swiftLocalizedStandardCompare` collation.
    public static let localizedStandardCompare = DatabaseCollation(
      "swiftLocalizedStandardCompare"
    ) { $0.localizedStandardCompare($1) }
  }

  extension Database {
    // GRDB installs these on every connection. Engines without custom functions or collations
    // skip them.
    func installDefaultFunctionsAndCollations() {
      let functions: [DatabaseFunction] = [
        .capitalize, .lowercase, .uppercase, .localizedCapitalize, .localizedLowercase,
        .localizedUppercase
      ]
      for function in functions {
        _ = try? access.withConnectionAccess { try function.install($0) }
      }
      let collations: [DatabaseCollation] = [
        .unicodeCompare, .caseInsensitiveCompare, .localizedCaseInsensitiveCompare,
        .localizedCompare, .localizedStandardCompare
      ]
      for collation in collations {
        _ = try? access.withConnectionAccess { try collation.install($0) }
      }
    }

    /// Makes a function unavailable on this connection. SQLiteOrbit cannot unregister functions,
    /// so the name is replaced by a function that fails with `no such function`.
    public func remove(function: DatabaseFunction) {
      let name = function.name
      add(
        function: DatabaseFunction(name, argumentCount: function.argumentCount) { _ in
          throw DatabaseError(message: "no such function: \(name)")
        }
      )
    }

    /// Makes a collation unavailable on this connection. SQLiteOrbit cannot unregister
    /// collations, so the collation is replaced by binary comparison.
    public func remove(collation: DatabaseCollation) {
      add(
        collation: DatabaseCollation(collation.name) { lhs, rhs in
          lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
            ? .orderedAscending : (lhs == rhs ? .orderedSame : .orderedDescending)
        }
      )
    }

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
          try access.withConnectionAccess { try collation.install($0) }
        }
      } catch {
        preconditionFailure(String(describing: error))
      }
    }
  }

#endif
