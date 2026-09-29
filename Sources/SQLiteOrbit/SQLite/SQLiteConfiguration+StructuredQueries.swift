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
      registerCollation(collation.name) { lhs, rhs in
        switch collation.compare(lhs, rhs) {
        case .ascending: .ascending
        case .same: .same
        case .descending: .descending
        }
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
#endif
