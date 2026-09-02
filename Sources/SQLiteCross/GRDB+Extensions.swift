#if GRDB
  import GRDB
  import GRDBSQLite
  public import StructuredQueriesSQLite

  extension Configuration {
    /// Installs `extensions` on every connection opened with this configuration.
    ///
    /// A collating sequence or function is only known to the connection it was installed on. A
    /// `DatabasePool` opens connections as it needs them, so installing on one connection leaves
    /// queries on every other connection failing with "no such collation sequence". Registering
    /// through the configuration covers connections opened later, too.
    ///
    /// ```swift
    /// var extensions = DatabaseExtensions()
    /// extensions.add(collation: $localized)
    ///
    /// var configuration = Configuration()
    /// configuration.register(extensions)
    ///
    /// let database = CrossProcessDatabase(
    ///   writer: try DatabasePool(path: path, configuration: configuration)
    /// )
    /// ```
    public mutating func register(_ extensions: DatabaseExtensions) {
      prepareDatabase { database in
        for collation in extensions.collations {
          database.install(collation: collation)
        }
        for function in extensions.scalarFunctions {
          database.install(function: function)
        }
        for function in extensions.aggregateFunctions {
          database.install(function: function)
        }
      }
    }
  }

  extension Database {
    /// Installs a Swift-implemented collating sequence on this connection.
    ///
    /// Prefer ``GRDB/Configuration/register(_:)``, which covers every connection a pool opens.
    public func install(collation: some StructuredQueriesSQLiteCore.DatabaseCollation) {
      sqlite3_create_collation_v2(
        sqliteConnection,
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

    /// Installs a Swift-implemented scalar function on this connection.
    ///
    /// Prefer ``GRDB/Configuration/register(_:)``, which covers every connection a pool opens.
    public func install(function: some ScalarDatabaseFunction) {
      sqlite3_create_function_v2(
        sqliteConnection,
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

    /// Installs a Swift-implemented aggregate function on this connection.
    ///
    /// Prefer ``GRDB/Configuration/register(_:)``, which covers every connection a pool opens.
    public func install(function: some AggregateDatabaseFunction) {
      sqlite3_create_function_v2(
        sqliteConnection,
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
          invocation.result.result(context)
          Unmanaged.passUnretained(invocation).release()
        },
        { Box<any AggregateDatabaseFunction>.release($0) }
      )
    }
  }

  /// Carries a Swift value through SQLite's `void *` user data, which SQLite owns for as long as
  /// the collation or function is registered and hands to its destructor when it is dropped.
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
  private class AggregateFunctionInvocation {
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
