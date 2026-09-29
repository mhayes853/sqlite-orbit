typealias SQLiteScalarFunctionBody =
  @Sendable (borrowing SQLiteFunctionArguments) throws -> OrbitDatabaseValue

typealias SQLiteAggregateAccumulatorFactory = @Sendable () -> any SQLiteAggregateAccumulator

func orbitInstallFunction(
  _ name: String,
  argumentCount: Int?,
  isDeterministic: Bool,
  body: @escaping SQLiteScalarFunctionBody,
  on connection: OpaquePointer?,
  library: SQLiteLibrary
) -> Int32 {
  name.withCString { name in
    library.scalarFunctions!
      .register(
        connection,
        name,
        Int32(argumentCount ?? -1),
        orbitFunctionFlags(isDeterministic: isDeterministic),
        Box.retain(body),
        { context, argumentCount, arguments in
          let library = SQLiteCurrentLibrary.current
          let functions = library.pointee.scalarFunctions!
          let body = Box<SQLiteScalarFunctionBody>
            .value(in: functions.callbacks.context.userData(context))
          let arguments = SQLiteFunctionArguments(
            count: argumentCount,
            values: arguments,
            api: functions.callbacks.argument
          )
          do {
            try body(arguments).result(context, using: functions.callbacks.result)
          } catch {
            orbitResultError(error, context, using: functions.callbacks.result)
          }
        },
        nil,
        nil,
        { Box<SQLiteScalarFunctionBody>.release($0) }
      )
  }
}

func orbitInstallAggregateFunction(
  _ name: String,
  argumentCount: Int?,
  isDeterministic: Bool,
  makeAccumulator: @escaping SQLiteAggregateAccumulatorFactory,
  on connection: OpaquePointer?,
  library: SQLiteLibrary
) -> Int32 {
  name.withCString { name in
    library.aggregateFunctions!
      .register(
        connection,
        name,
        Int32(argumentCount ?? -1),
        orbitFunctionFlags(isDeterministic: isDeterministic),
        Box.retain(makeAccumulator),
        nil,
        { context, argumentCount, arguments in
          let library = SQLiteCurrentLibrary.current
          let functions = library.pointee.aggregateFunctions!
          let arguments = SQLiteFunctionArguments(
            count: argumentCount,
            values: arguments,
            api: functions.callbacks.argument
          )
          do {
            try AggregateFunctionInvocation.current(in: context, library: library)
              .accumulator.step(arguments)
          } catch {
            orbitResultError(error, context, using: functions.callbacks.result)
          }
        },
        { context in
          let library = SQLiteCurrentLibrary.current
          let functions = library.pointee.aggregateFunctions!
          let invocation = AggregateFunctionInvocation.current(in: context, library: library)
          do {
            try invocation.accumulator.finish().result(context, using: functions.callbacks.result)
          } catch {
            orbitResultError(error, context, using: functions.callbacks.result)
          }
          Unmanaged.passUnretained(invocation).release()
        },
        { Box<SQLiteAggregateAccumulatorFactory>.release($0) }
      )
  }
}

private func orbitFunctionFlags(isDeterministic: Bool) -> Int32 {
  var flags = SQLiteFunctionFlags.utf8
  if isDeterministic {
    flags.insert(.deterministic)
  }
  return flags.rawValue
}

private func orbitResultError(
  _ error: any Error,
  _ context: OpaquePointer?,
  using result: SQLiteLibrary.FunctionCallbacks.Result
) {
  "\(error)".withCString { result.error(context, $0, -1) }
}

extension OrbitDatabaseValue {
  // The table's result entry points copy what they are handed, so nothing here has to outlive the
  // call the way `SQLITE_TRANSIENT` would otherwise demand.
  func result(_ context: OpaquePointer?, using result: SQLiteLibrary.FunctionCallbacks.Result) {
    switch self {
    case .blob(let bytes):
      bytes.withUnsafeBytes { buffer in
        // SQLite interprets a null pointer as SQL NULL even when its byte count is zero.
        guard let baseAddress = buffer.baseAddress else {
          var empty: UInt8 = 0
          return withUnsafeBytes(of: &empty) { result.blob(context, $0.baseAddress, 0) }
        }
        result.blob(context, baseAddress, Int32(buffer.count))
      }
    case .real(let double):
      result.double(context, double)
    case .integer(let integer):
      result.int64(context, integer)
    case .null:
      result.null(context)
    case .text(let text):
      text.withCString { result.text(context, $0, Int32(text.utf8.count)) }
    }
  }
}

final class Box<Value> {
  let value: Value

  private init(_ value: Value) {
    self.value = value
  }

  static func retain(_ value: Value) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(Box(value)).toOpaque()
  }

  static func value(in pointer: UnsafeMutableRawPointer?) -> Value {
    Unmanaged<Box>.fromOpaque(pointer!).takeUnretainedValue().value
  }

  static func release(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<Box>.fromOpaque(pointer).release()
  }
}

private final class AggregateFunctionInvocation {
  // SQLite's callbacks are not generic, so the accumulator's type is erased.
  var accumulator: any SQLiteAggregateAccumulator

  init(_ accumulator: any SQLiteAggregateAccumulator) {
    self.accumulator = accumulator
  }

  static func current(
    in context: OpaquePointer?,
    library: UnsafePointer<SQLiteLibrary>
  ) -> AggregateFunctionInvocation {
    let functions = library.pointee.aggregateFunctions!
    let slot = functions.context(
      context,
      Int32(MemoryLayout<Unmanaged<AggregateFunctionInvocation>>.size)
    )!
    .assumingMemoryBound(to: Unmanaged<AggregateFunctionInvocation>?.self)
    if let invocation = slot.pointee {
      return invocation.takeUnretainedValue()
    }
    let userData = functions.callbacks.context.userData(context)
    let makeAccumulator = Box<SQLiteAggregateAccumulatorFactory>.value(in: userData)
    let invocation = Unmanaged.passRetained(AggregateFunctionInvocation(makeAccumulator()))
    slot.pointee = invocation
    return invocation.takeUnretainedValue()
  }
}
