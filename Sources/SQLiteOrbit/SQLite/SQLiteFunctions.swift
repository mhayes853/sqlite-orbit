/// The arguments SQL passed to a function registered on a connection.
///
/// The arguments are a view onto SQLite's own values, so they are only valid during the call that
/// lent them and cannot be stored or escape it.
///
/// ```swift
/// configuration.registerFunction("repeated", argumentCount: 2) { arguments in
///   guard
///     let text = arguments[0].textValue,
///     let count = arguments[1].integerValue
///   else { return nil }
///   return .text(String(repeating: text, count: Int(count)))
/// }
/// ```
public struct SQLiteFunctionArguments: ~Copyable, ~Escapable {
  let rawCount: Int32
  let values: UnsafeMutablePointer<OpaquePointer?>?
  let api: SQLiteLibrary.FunctionCallbacks.Argument

  @_lifetime(immortal)
  init(
    count: Int32,
    values: UnsafeMutablePointer<OpaquePointer?>?,
    api: SQLiteLibrary.FunctionCallbacks.Argument
  ) {
    self.rawCount = count
    self.values = values
    self.api = api
  }

  /// How many arguments the function was called with.
  public var count: Int {
    Int(rawCount)
  }

  /// An argument, in the storage class SQLite holds it in.
  ///
  /// - Parameter index: The argument's zero-based position. A position outside the arguments
  ///   stops the process.
  public subscript(index: Int) -> OrbitDatabaseValue {
    precondition(
      index >= 0 && index < count,
      "Argument index \(index) is out of range for a call with \(count) arguments"
    )
    return api.value(values?[index])
  }
}

/// The state an aggregate function builds up over the rows of one group.
///
/// A new accumulator is made for every group the aggregate runs over, handed each row's arguments
/// in turn, and asked for the result once the group ends. A group with no rows is asked for its
/// result without any step.
///
/// ```swift
/// struct LongestText: SQLiteAggregateAccumulator {
///   var longest: String?
///
///   mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
///     guard let text = arguments[0].textValue else { return }
///     if text.count > longest?.count ?? -1 { longest = text }
///   }
///
///   func finish() throws -> OrbitDatabaseValue {
///     longest.map(OrbitDatabaseValue.text) ?? nil
///   }
/// }
///
/// configuration.registerAggregateFunction("longest", argumentCount: 1) { LongestText() }
/// ```
public protocol SQLiteAggregateAccumulator {
  /// Adds one row's arguments to the accumulated state.
  ///
  /// - Parameter arguments: The row's arguments, valid only for this call.
  /// - Throws: An error that fails the statement running the aggregate, with the error's
  ///   description as its message.
  mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws

  /// Returns the aggregate's result for the group.
  ///
  /// - Returns: The value SQL sees.
  /// - Throws: An error that fails the statement running the aggregate, with the error's
  ///   description as its message.
  func finish() throws -> OrbitDatabaseValue
}

extension SQLiteConfiguration {
  /// Registers a scalar function on every connection opened with this configuration.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.registerFunction("reversed", argumentCount: 1, isDeterministic: true) {
  ///   arguments in
  ///   arguments[0].textValue.map { .text(String($0.reversed())) } ?? nil
  /// }
  /// ```
  ///
  /// A function that throws fails the statement that called it, with the error's description as
  /// SQLite's message.
  ///
  /// - Parameters:
  ///   - name: The name SQL calls the function by.
  ///   - argumentCount: How many arguments the function takes, or `nil` for any number.
  ///   - isDeterministic: Whether the function always returns the same result for the same
  ///     arguments, which lets SQLite use it in indexes and factor it out of loops.
  ///   - body: Computes the result from the arguments, which are only valid during the call.
  public mutating func registerFunction(
    _ name: String,
    argumentCount: Int?,
    isDeterministic: Bool = false,
    _ body: @escaping @Sendable (borrowing SQLiteFunctionArguments) throws -> OrbitDatabaseValue
  ) {
    register(.scalarFunctions, providedBy: \.scalarFunctions) { connection in
      orbitInstallFunction(
        name,
        argumentCount: argumentCount,
        isDeterministic: isDeterministic,
        body: body,
        on: connection.sqliteConnection,
        library: connection.sqlite
      )
    }
  }

  /// Registers an aggregate function on every connection opened with this configuration.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.registerAggregateFunction("longest", argumentCount: 1) { LongestText() }
  /// ```
  ///
  /// - Parameters:
  ///   - name: The name SQL calls the function by.
  ///   - argumentCount: How many arguments the function takes, or `nil` for any number.
  ///   - isDeterministic: Whether the function always returns the same result for the same rows.
  ///   - makeAccumulator: Makes the empty state for one group, which is called once for every
  ///     group the aggregate runs over.
  public mutating func registerAggregateFunction<Accumulator: SQLiteAggregateAccumulator>(
    _ name: String,
    argumentCount: Int?,
    isDeterministic: Bool = false,
    _ makeAccumulator: @escaping @Sendable () -> Accumulator
  ) {
    let makeAccumulator: SQLiteAggregateAccumulatorFactory = makeAccumulator
    register(.aggregateFunctions, providedBy: \.aggregateFunctions) { connection in
      orbitInstallAggregateFunction(
        name,
        argumentCount: argumentCount,
        isDeterministic: isDeterministic,
        makeAccumulator: makeAccumulator,
        on: connection.sqliteConnection,
        library: connection.sqlite
      )
    }
  }
}
