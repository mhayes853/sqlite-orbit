#if SystemSQLite
  import CSQLite3
  import StructuredQueriesSQLite

  func orbitInstall(
    collation: some StructuredQueriesSQLiteCore.DatabaseCollation,
    on connection: OpaquePointer?
  ) -> Int32 {
    sqlite3_create_collation_v2(
      connection,
      collation.name,
      SQLITE_UTF8,
      Box.retain(collation as any StructuredQueriesSQLiteCore.DatabaseCollation),
      { box, lhsCount, lhs, rhsCount, rhs in
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

  func orbitInstall(
    function: some ScalarDatabaseFunction,
    on connection: OpaquePointer?
  ) -> Int32 {
    sqlite3_create_function_v2(
      connection,
      function.name,
      Int32(function.argumentCount ?? -1),
      SQLITE_UTF8 | (function.isDeterministic ? SQLITE_DETERMINISTIC : 0),
      Box.retain(function as any ScalarDatabaseFunction),
      { context, argumentCount, arguments in
        let function = Box<any ScalarDatabaseFunction>.value(in: sqlite3_user_data(context))
        var decoder = SQLiteFunctionDecoder(argumentCount: argumentCount, arguments: arguments)
        do {
          try function.invoke(&decoder).result(context)
        } catch {
          QueryBinding.invalid(error).result(context)
        }
      },
      nil,
      nil,
      { Box<any ScalarDatabaseFunction>.release($0) }
    )
  }

  func orbitInstall(
    function: some AggregateDatabaseFunction,
    on connection: OpaquePointer?
  ) -> Int32 {
    sqlite3_create_function_v2(
      connection,
      function.name,
      Int32(function.argumentCount ?? -1),
      SQLITE_UTF8 | (function.isDeterministic ? SQLITE_DETERMINISTIC : 0),
      Box.retain(function as any AggregateDatabaseFunction),
      nil,
      { context, argumentCount, arguments in
        var decoder = SQLiteFunctionDecoder(argumentCount: argumentCount, arguments: arguments)
        do {
          try AggregateFunctionInvocation.current(in: context).step(&decoder)
        } catch {
          QueryBinding.invalid(error).result(context)
        }
      },
      { context in
        let invocation = AggregateFunctionInvocation.current(in: context)
        invocation.result().result(context)
        Unmanaged.passUnretained(invocation).release()
      },
      { Box<any AggregateDatabaseFunction>.release($0) }
    )
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

    static func current(in context: OpaquePointer?) -> AggregateFunctionInvocation {
      let slot = sqlite3_aggregate_context(
        context,
        Int32(MemoryLayout<Unmanaged<AggregateFunctionInvocation>>.size)
      )!
      .assumingMemoryBound(to: Unmanaged<AggregateFunctionInvocation>?.self)
      if let invocation = slot.pointee {
        return invocation.takeUnretainedValue()
      }
      let function = Box<any AggregateDatabaseFunction>.value(in: sqlite3_user_data(context))
      let invocation = Unmanaged.passRetained(AggregateFunctionInvocation(function))
      slot.pointee = invocation
      return invocation.takeUnretainedValue()
    }
  }
#endif
