#if GRDB
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
  final class AggregateFunctionInvocation {
    // SQLite's callbacks are not generic, so the function's element type is erased behind these
    // two closures. They share the rows collected so far.
    private let appendRow: (inout SQLiteFunctionDecoder) throws -> Void
    private let aggregate: () -> QueryBinding

    init<Function: AggregateDatabaseFunction>(_ function: Function) {
      let rows = Rows<Function.Element>()
      self.appendRow = { decoder in
        rows.elements.append(try function.step(&decoder))
      }
      self.aggregate = {
        do {
          return try function.invoke(rows.elements)
        } catch {
          return .invalid(error)
        }
      }
    }

    /// Decodes one row into the group.
    func step(_ decoder: inout SQLiteFunctionDecoder) throws {
      try appendRow(&decoder)
    }

    /// Runs the body over the collected rows. Called once, when SQLite ends the group.
    var result: QueryBinding {
      aggregate()
    }

    private final class Rows<Element> {
      var elements: [Element] = []
    }
  }
#endif
