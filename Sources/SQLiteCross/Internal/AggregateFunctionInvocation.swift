#if GRDB
  import GRDBSQLite
  import StructuredQueriesSQLite

  /// One aggregation in progress.
  ///
  /// SQLite pushes rows one at a time through its `xStep` callback, while an aggregate body takes
  /// them all at once as a `Sequence`. Collecting the rows and running the body from `xFinal`
  /// bridges the two without leaving the thread SQLite called on.
  ///
  /// This holds a whole group in memory. Handing the body a sequence that produced rows as SQLite
  /// stepped would bound that, but `invoke` is synchronous and SQLite drives the loop, so it would
  /// mean running the body on another thread and blocking it between rows. That trades memory local
  /// to one query for a thread held for the length of every aggregation, and only pays off for
  /// bodies that consume their sequence lazily to begin with.
  class AggregateFunctionInvocation {
    /// The invocation for the aggregation `context` belongs to, creating it on first use.
    ///
    /// SQLite allocates one slot per aggregation, so each group gets its own invocation. The slot
    /// holds an unbalanced retain that `xFinal` releases.
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
      let invocation = Unmanaged.passRetained(Self.make(function))
      slot.pointee = invocation
      return invocation.takeUnretainedValue()
    }

    // SQLite's callbacks are not generic, so the function's element type lives in a subclass.
    private static func make(
      _ function: some AggregateDatabaseFunction
    ) -> AggregateFunctionInvocation {
      Typed(function)
    }

    func step(_ decoder: inout SQLiteFunctionDecoder) throws { fatalError("abstract") }
    var result: QueryBinding { fatalError("abstract") }

    private final class Typed<Function: AggregateDatabaseFunction>: AggregateFunctionInvocation {
      let function: Function
      var rows: [Function.Element] = []

      init(_ function: Function) {
        self.function = function
      }

      override func step(_ decoder: inout SQLiteFunctionDecoder) throws {
        rows.append(try function.step(&decoder))
      }

      override var result: QueryBinding {
        do {
          return try function.invoke(rows)
        } catch {
          return .invalid(error)
        }
      }
    }
  }
#endif
