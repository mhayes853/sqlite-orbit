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
      guard !extensions.isEmpty else { return }
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
        // SQLite owns the comparator for as long as the collation is registered, and hands it back
        // on every comparison. The destructor below balances this retain.
        Unmanaged.passRetained(DatabaseCollationBox(collation)).toOpaque(),
        { box, lhsCount, lhs, rhsCount, rhs in
          let collation = Unmanaged<DatabaseCollationBox>
            .fromOpaque(box!)
            .takeUnretainedValue()
            .collation
          switch collation.compare(
            UnsafeRawBufferPointer(start: lhs, count: Int(lhsCount)),
            UnsafeRawBufferPointer(start: rhs, count: Int(rhsCount))
          ) {
          case .ascending: return -1
          case .same: return 0
          case .descending: return 1
          }
        },
        { box in
          guard let box else { return }
          Unmanaged<DatabaseCollationBox>.fromOpaque(box).release()
        }
      )
    }
  }

  extension Database {
    /// Installs a Swift-implemented scalar function on this connection.
    ///
    /// Prefer ``GRDB/Configuration/register(_:)``, which covers every connection a pool opens.
    public func install(function: some ScalarDatabaseFunction) {
      sqlite3_create_function_v2(
        sqliteConnection,
        function.name,
        Int32(function.argumentCount ?? -1),
        SQLITE_UTF8 | (function.isDeterministic ? SQLITE_DETERMINISTIC : 0),
        Unmanaged.passRetained(ScalarFunctionBox(function)).toOpaque(),
        { context, argumentCount, arguments in
          let function = Unmanaged<ScalarFunctionBox>
            .fromOpaque(sqlite3_user_data(context))
            .takeUnretainedValue()
            .function
          var decoder = SQLiteFunctionDecoder(argumentCount: argumentCount, arguments: arguments)
          do {
            try function.invoke(&decoder).result(context)
          } catch {
            QueryBinding.invalid(error).result(context)
          }
        },
        nil,
        nil,
        { box in
          guard let box else { return }
          Unmanaged<ScalarFunctionBox>.fromOpaque(box).release()
        }
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
        Unmanaged.passRetained(AggregateFunctionBox(function)).toOpaque(),
        nil,
        { context, argumentCount, arguments in
          // SQLite allocates one slot per aggregation, so each group gets its own invocation.
          let invocation = AggregateFunctionBox.invocation(for: context).takeUnretainedValue()
          var decoder = SQLiteFunctionDecoder(argumentCount: argumentCount, arguments: arguments)
          do {
            try invocation.step(&decoder)
          } catch {
            QueryBinding.invalid(error).result(context)
          }
        },
        { context in
          let unmanaged = AggregateFunctionBox.invocation(for: context)
          let invocation = unmanaged.takeUnretainedValue()
          unmanaged.release()
          invocation.finish()
          invocation.result.result(context)
        },
        { box in
          guard let box else { return }
          Unmanaged<AggregateFunctionBox>.fromOpaque(box).release()
        }
      )
    }
  }

  private final class ScalarFunctionBox {
    let function: any ScalarDatabaseFunction

    init(_ function: some ScalarDatabaseFunction) {
      self.function = function
    }
  }

  /// Holds the aggregate function, and vends the per-aggregation invocation SQLite keys off its
  /// own context allocation.
  private final class AggregateFunctionBox {
    let makeInvocation: () -> any AggregateFunctionInvocationProtocol

    init(_ function: some AggregateDatabaseFunction) {
      self.makeInvocation = { AggregateFunctionInvocation(function) }
    }

    static func invocation(
      for context: OpaquePointer?
    ) -> Unmanaged<AnyAggregateFunctionInvocation> {
      let size = MemoryLayout<Unmanaged<AnyAggregateFunctionInvocation>>.size
      let slot = sqlite3_aggregate_context(context, Int32(size))!
      if slot.load(as: Int.self) == 0 {
        let box = Unmanaged<AggregateFunctionBox>
          .fromOpaque(sqlite3_user_data(context))
          .takeUnretainedValue()
        let unmanaged = Unmanaged.passRetained(
          AnyAggregateFunctionInvocation(box.makeInvocation())
        )
        slot
          .assumingMemoryBound(to: Unmanaged<AnyAggregateFunctionInvocation>.self)
          .pointee = unmanaged
        return unmanaged
      }
      return
        slot
        .assumingMemoryBound(to: Unmanaged<AnyAggregateFunctionInvocation>.self)
        .pointee
    }
  }

  private final class DatabaseCollationBox {
    let collation: any StructuredQueriesSQLiteCore.DatabaseCollation

    init(_ collation: any StructuredQueriesSQLiteCore.DatabaseCollation) {
      self.collation = collation
    }
  }
#endif
