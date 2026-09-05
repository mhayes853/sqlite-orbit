import StructuredQueriesSQLite

func orbitInstall(
  collation: some StructuredQueriesSQLiteCore.DatabaseCollation,
  on connection: OpaquePointer?,
  library: SQLiteLibrary
) -> Int32 {
  collation.name.withCString { name in
    library.create_collation_v2(
      connection,
      name,
      SQLiteFunctionFlags.utf8.rawValue,
      Box.retain(collation as any StructuredQueriesSQLiteCore.DatabaseCollation),
      { box, lhsCount, lhs, rhsCount, rhs in
        // A comparator is handed its user data directly, so it is the one callback that needs
        // nothing from the build that called it.
        let collation = Box<any StructuredQueriesSQLiteCore.DatabaseCollation>.value(in: box)
        switch collation.compare(
          UnsafeRawBufferPointer(start: lhs, count: Int(lhsCount)),
          UnsafeRawBufferPointer(start: rhs, count: Int(rhsCount))
        ) {
        case .ascending: return -1
        case .same: return 0
        case .descending: return 1
        }
      },
      { Box<any StructuredQueriesSQLiteCore.DatabaseCollation>.release($0) }
    )
  }
}

func orbitInstall(
  function: some ScalarDatabaseFunction,
  on connection: OpaquePointer?,
  library: SQLiteLibrary
) -> Int32 {
  function.name.withCString { name in
    library.create_function_v2(
      connection,
      name,
      Int32(function.argumentCount ?? -1),
      orbitFunctionFlags(isDeterministic: function.isDeterministic),
      Box.retain(function as any ScalarDatabaseFunction),
      { context, argumentCount, arguments in
        let library = SQLiteCurrentLibrary.current
        let function = Box<any ScalarDatabaseFunction>.value(in: library.pointee.user_data(context))
        var decoder = SQLiteFunctionDecoder(
          argumentCount: argumentCount,
          arguments: arguments,
          library: library
        )
        do {
          try function.invoke(&decoder).result(context, library: library)
        } catch {
          QueryBinding.invalid(error).result(context, library: library)
        }
      },
      nil,
      nil,
      { Box<any ScalarDatabaseFunction>.release($0) }
    )
  }
}

func orbitInstall(
  function: some AggregateDatabaseFunction,
  on connection: OpaquePointer?,
  library: SQLiteLibrary
) -> Int32 {
  function.name.withCString { name in
    library.create_function_v2(
      connection,
      name,
      Int32(function.argumentCount ?? -1),
      orbitFunctionFlags(isDeterministic: function.isDeterministic),
      Box.retain(function as any AggregateDatabaseFunction),
      nil,
      { context, argumentCount, arguments in
        let library = SQLiteCurrentLibrary.current
        var decoder = SQLiteFunctionDecoder(
          argumentCount: argumentCount,
          arguments: arguments,
          library: library
        )
        do {
          try AggregateFunctionInvocation.current(in: context, library: library).step(&decoder)
        } catch {
          QueryBinding.invalid(error).result(context, library: library)
        }
      },
      { context in
        let library = SQLiteCurrentLibrary.current
        let invocation = AggregateFunctionInvocation.current(in: context, library: library)
        invocation.result().result(context, library: library)
        Unmanaged.passUnretained(invocation).release()
      },
      { Box<any AggregateDatabaseFunction>.release($0) }
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

private final class Box<Value> {
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
  let step: (inout SQLiteFunctionDecoder) throws -> Void

  let result: () -> QueryBinding

  // SQLite's callbacks are not generic, so the function's element type is erased behind the two
  // closures, which share the rows collected so far.
  init<Function: AggregateDatabaseFunction>(_ function: Function) {
    var rows: [Function.Element] = []
    step = { decoder in rows.append(try function.step(&decoder)) }
    result = {
      do {
        return try function.invoke(rows)
      } catch {
        return .invalid(error)
      }
    }
  }

  static func current(
    in context: OpaquePointer?,
    library: UnsafePointer<SQLiteLibrary>
  ) -> AggregateFunctionInvocation {
    let slot = library.pointee.aggregate_context(
      context,
      Int32(MemoryLayout<Unmanaged<AggregateFunctionInvocation>>.size)
    )!
    .assumingMemoryBound(to: Unmanaged<AggregateFunctionInvocation>?.self)
    if let invocation = slot.pointee {
      return invocation.takeUnretainedValue()
    }
    let userData = library.pointee.user_data(context)
    let function = Box<any AggregateDatabaseFunction>.value(in: userData)
    let invocation = Unmanaged.passRetained(AggregateFunctionInvocation(function))
    slot.pointee = invocation
    return invocation.takeUnretainedValue()
  }
}
