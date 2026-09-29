#if StructuredQueries
  public import StructuredQueriesSQLite

  extension SQLiteConfiguration {
    /// Registers a collating sequence on every connection opened with this configuration.
    ///
    /// ```swift
    /// var configuration = SQLiteConfiguration.default
    /// configuration.register(collation: CaseInsensitiveCollation())
    /// ```
    ///
    /// - Parameter collation: The collation to install. Its name is what SQL refers to it by.
    public mutating func register(
      collation: some StructuredQueriesSQLiteCore.DatabaseCollation & Sendable
    ) {
      register(.collations, providedBy: \.collations) { connection in
        orbitInstall(
          collation: collation,
          on: connection.sqliteConnection,
          library: connection.sqlite
        )
      }
    }

    /// Registers a scalar function on every connection opened with this configuration.
    ///
    /// ```swift
    /// @DatabaseFunction(isDeterministic: true)
    /// func repeated(_ text: String, _ count: Int) -> String {
    ///   String(repeating: text, count: count)
    /// }
    ///
    /// var configuration = SQLiteConfiguration.default
    /// configuration.register(function: $repeated)
    /// ```
    ///
    /// - Parameter function: The function to install. Its name is what SQL calls it by.
    public mutating func register(function: some ScalarDatabaseFunction & Sendable) {
      registerFunction(
        function.name,
        argumentCount: function.argumentCount,
        isDeterministic: function.isDeterministic
      ) { arguments in
        var decoder = SQLiteFunctionDecoder(arguments)
        return try OrbitDatabaseValue(lowering: function.invoke(&decoder))
      }
    }

    /// Registers an aggregate function on every connection opened with this configuration.
    ///
    /// ```swift
    /// var configuration = SQLiteConfiguration.default
    /// configuration.register(function: $longestTitle)
    /// ```
    ///
    /// - Parameter function: The function to install. Its name is what SQL calls it by.
    public mutating func register(function: some AggregateDatabaseFunction & Sendable) {
      registerAggregateFunction(
        function.name,
        argumentCount: function.argumentCount,
        isDeterministic: function.isDeterministic
      ) {
        StructuredQueriesAggregateAccumulator(function: function)
      }
    }
  }

  // Collects each row's decoded element and hands them all to the function at the end, which is the
  // shape Structured Queries gives an aggregate.
  private struct StructuredQueriesAggregateAccumulator<Function: AggregateDatabaseFunction>:
    SQLiteAggregateAccumulator
  {
    let function: Function
    var rows: [Function.Element] = []

    mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
      var decoder = SQLiteFunctionDecoder(arguments)
      rows.append(try function.step(&decoder))
    }

    func finish() throws -> OrbitDatabaseValue {
      try OrbitDatabaseValue(lowering: function.invoke(rows))
    }
  }

  func orbitInstall(
    collation: some StructuredQueriesSQLiteCore.DatabaseCollation,
    on connection: OpaquePointer?,
    library: SQLiteLibrary
  ) -> Int32 {
    let box = Box.retain(collation as any StructuredQueriesSQLiteCore.DatabaseCollation)
    let code = collation.name.withCString { name in
      library.collations!
        .create(
          connection,
          name,
          SQLiteFunctionFlags.utf8.rawValue,
          box,
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
    // A registration that fails takes the collation with it, and SQLite only calls the destructor
    // of one that succeeded — unlike `sqlite3_create_function_v2`, which calls it either way.
    if code != SQLiteResultCode.ok.rawValue {
      Box<any StructuredQueriesSQLiteCore.DatabaseCollation>.release(box)
    }
    return code
  }
#endif
