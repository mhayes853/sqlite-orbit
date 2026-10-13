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
/// configuration.registerAggregateFunction("longest", argumentCount: 1, LongestText())
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
  /// configuration.registerFunction("reversed", argumentCount: 1, flags: [.deterministic]) {
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
  ///   - flags: Function behavior, such as determinism or restrictions on schema use.
  ///     The Swift bridge always uses UTF-8, regardless of encoding bits in this value.
  ///   - body: Computes the result from the arguments, which are only valid during the call.
  public mutating func registerFunction(
    _ name: String,
    argumentCount: Int?,
    flags: SQLiteFunctionFlags = [],
    _ body: @escaping @Sendable (borrowing SQLiteFunctionArguments) throws -> OrbitDatabaseValue
  ) {
    register { connection in
      try connection.registerFunction(name, argumentCount: argumentCount, flags: flags, body)
    }
  }

  /// Registers an aggregate function on every connection opened with this configuration.
  ///
  /// ```swift
  /// var configuration = SQLiteConfiguration.default
  /// configuration.registerAggregateFunction("longest", argumentCount: 1, LongestText())
  /// ```
  ///
  /// - Parameters:
  ///   - name: The name SQL calls the function by.
  ///   - argumentCount: How many arguments the function takes, or `nil` for any number.
  ///   - flags: Function behavior. The Swift bridge always uses UTF-8.
  ///   - makeAccumulator: Makes the empty state for one group, which is called once for every
  ///     group the aggregate runs over.
  public mutating func registerAggregateFunction<Accumulator: SQLiteAggregateAccumulator>(
    _ name: String,
    argumentCount: Int?,
    flags: SQLiteFunctionFlags = [],
    _ makeAccumulator: @autoclosure @escaping @Sendable () -> Accumulator
  ) {
    register { connection in
      try connection.registerAggregateFunction(
        name,
        argumentCount: argumentCount,
        flags: flags,
        makeAccumulator()
      )
    }
  }
}

extension SQLiteConnectionAccess {
  /// Installs a scalar function on this connection.
  ///
  /// The connection retains the body until the function is replaced or the connection closes.
  /// Throwing from the body fails the calling statement with the error's description.
  ///
  /// - Parameters:
  ///   - name: The name SQL calls the function by.
  ///   - argumentCount: A nonnegative argument count, or `nil` for any number.
  ///   - flags: Function behavior. Encoding bits are ignored; the bridge always uses UTF-8.
  ///   - body: Computes a result from arguments valid only during the call.
  /// - Throws: A `SQLiteFeatureUnavailableError` if the library lacks scalar functions, or a
  ///   `SQLiteError` if registration fails.
  public borrowing func registerFunction(
    _ name: String,
    argumentCount: Int?,
    flags: SQLiteFunctionFlags = [],
    _ body: @escaping @Sendable (borrowing SQLiteFunctionArguments) throws -> OrbitDatabaseValue
  ) throws {
    try validateFunction(name, argumentCount: argumentCount)
    try install(.scalarFunctions, providedBy: sqlite.scalarFunctions) {
      orbitInstallFunction(
        name,
        argumentCount: argumentCount,
        flags: flags,
        body: body,
        on: sqliteConnection,
        library: sqlite
      )
    }
  }

  /// Installs an aggregate function on this connection.
  ///
  /// The connection retains the factory until replacement or close. The expression is evaluated
  /// once per group, including empty groups, and each group's accumulator is released at its end.
  ///
  /// - Parameters:
  ///   - name: The name SQL calls the aggregate by.
  ///   - argumentCount: A nonnegative argument count, or `nil` for any number.
  ///   - flags: Function behavior. Encoding bits are ignored; the bridge always uses UTF-8.
  ///   - makeAccumulator: Creates fresh state for each group.
  /// - Throws: A `SQLiteFeatureUnavailableError` if the library lacks aggregates, or a
  ///   `SQLiteError` if registration fails.
  public borrowing func registerAggregateFunction<Accumulator: SQLiteAggregateAccumulator>(
    _ name: String,
    argumentCount: Int?,
    flags: SQLiteFunctionFlags = [],
    _ makeAccumulator: @autoclosure @escaping @Sendable () -> Accumulator
  ) throws {
    try validateFunction(name, argumentCount: argumentCount)
    try install(.aggregateFunctions, providedBy: sqlite.aggregateFunctions) {
      orbitInstallAggregateFunction(
        name,
        argumentCount: argumentCount,
        flags: flags,
        makeAccumulator: makeAccumulator,
        on: sqliteConnection,
        library: sqlite
      )
    }
  }

  private borrowing func validateFunction(_ name: String, argumentCount: Int?) throws {
    guard !name.utf8.contains(0),
      argumentCount.map({ $0 >= 0 && Int32(exactly: $0) != nil }) ?? true
    else {
      throw SQLiteError(code: .misuse, message: "Invalid function name or argument count")
    }
  }

  borrowing func install<Group>(
    _ feature: SQLiteLibraryFeature,
    providedBy group: Group?,
    _ body: () -> Int32
  ) throws {
    guard group != nil else {
      throw SQLiteFeatureUnavailableError(libraryName: sqlite.name, feature: feature)
    }
    let code = body()
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError.reported(by: sqlite, on: sqliteConnection, code: code, sql: nil)
    }
  }
}
