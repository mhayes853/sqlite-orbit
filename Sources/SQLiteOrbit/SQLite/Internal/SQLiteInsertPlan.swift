#if StructuredQueries
  import StructuredQueriesSQLite

  // An `INSERT` built once for a table, and what binds each run's values to it.
  //
  // Structured Queries builds a statement's whole fragment, with a binding for every value, each
  // time it runs, which costs far more than the statement itself when a loop inserts one row
  // after another. A plan builds the SQL once, from the same table metadata the query builder
  // reads, and binds each row's values straight from the row through key paths extracted once,
  // so a run renders nothing, and builds no string or array.
  //
  // A plan never changes once built, so it is shared freely: the conveniences keep one per table
  // and conflict clause for the life of the process.
  final class SQLiteInsertPlan: @unchecked Sendable {
    // What to do with a row that conflicts with one already in the table.
    enum Conflict {
      case none
      case replace
      case ignore
      case update(keyColumns: [String])
    }

    let sql: String

    // `sql`, as the query the statement cache looks it up by. A query made of this one string is
    // matched against the cache's most recent statement by the string's identity, without
    // reading it, so every run of the plan hands over this same query.
    let query: SQL

    // One binder for each value a run is given, in order: a record insert's one record, or a
    // partial insert's one value per listed column.
    let binders: [SQLiteInsertBinder]

    let parameterCount: Int

    // Builds the SQL Structured Queries renders for `INSERT INTO <table> (<columns>) VALUES (…)`
    // with `conflict`, with a parameter in place of each value.
    init<Row: Table>(
      _ table: Row.Type,
      columnNames: [String],
      binders: [SQLiteInsertBinder],
      conflict: Conflict
    ) throws {
      let parameterCount = binders.reduce(0) { $0 + $1.parameterCount }
      guard parameterCount == columnNames.count, !columnNames.isEmpty else {
        throw SQLiteError(
          code: .misuse,
          message: """
            an insert into "\(Row.tableName)" names \(columnNames.count) columns, but its values \
            bind \(parameterCount)
            """
        )
      }
      var query: QueryFragment
      switch conflict {
      case .replace: query = "INSERT OR REPLACE INTO "
      case .none, .ignore, .update: query = "INSERT INTO "
      }
      if let schemaName = Row.schemaName {
        query.append("\(quote: schemaName).")
      }
      query.append("\(quote: Row.tableName)")
      if let tableAlias = Row.tableAlias {
        query.append(" AS \(quote: tableAlias)")
      }
      query.append(" (\(quoted(columnNames).joined(separator: ", ")))")
      query.append(
        " VALUES (\(raw: repeatElement("?", count: columnNames.count).joined(separator: ", ")))"
      )
      switch conflict {
      case .none, .replace:
        break
      case .ignore:
        // Not `INSERT OR IGNORE`, which also drops a row that breaks a NOT NULL or CHECK
        // constraint without a word. An upsert's DO NOTHING only skips a uniqueness conflict.
        query.append(" ON CONFLICT DO NOTHING")
      case .update(let keyColumns):
        for column in keyColumns where !columnNames.contains(column) {
          throw SQLiteError(
            code: .misuse,
            message: """
              an insert that updates a conflicting row of "\(Row.tableName)" must write its \
              primary key column "\(column)"
              """
          )
        }
        query.append(" ON CONFLICT (\(quoted(keyColumns).joined(separator: ", ")))")
        let updated = columnNames.filter { !keyColumns.contains($0) }
        if updated.isEmpty {
          // Nothing but the key is written, so a conflicting row already holds every value the
          // insert would write. Structured Queries' upsert renders the same for such a table.
          query.append(" DO NOTHING")
        } else {
          let assignments = updated.map { (column: String) -> QueryFragment in
            "\(quote: column) = \(quote: "excluded").\(quote: column)"
          }
          query.append(" DO UPDATE SET \(assignments.joined(separator: ", "))")
        }
      }
      self.sql = SQL(fragment: query).text
      self.query = SQL(text: sql)
      self.binders = binders
      self.parameterCount = parameterCount
    }

    // A plan that writes every writable column of a record or draft, generated columns aside, as
    // `Table.insert { row }` does.
    convenience init<Row: Table>(records table: Row.Type, conflict: Conflict) throws {
      let columns = Row.TableColumns.writableColumns
      var names: [String] = []
      names.reserveCapacity(columns.count)
      var binders: [SQLiteColumnBinder<Row>] = []
      binders.reserveCapacity(columns.count)
      for column in columns {
        names.append(column.name)
        binders.append(sqliteColumnBinder(column, of: Row.self))
      }
      try self.init(
        table,
        columnNames: names,
        binders: [SQLiteRecordBinder(columns: binders, offset: 0)],
        conflict: conflict
      )
    }

    // A plan that writes only the listed columns, each from a run's argument, as
    // `Table.insert { ($0.a, $0.b) } values: { (a, b) }` does.
    //
    // A run is handed its arguments as one tuple, so each argument is read at its offset in the
    // tuple.
    convenience init<Row: Table, each Column: _TableColumnExpression>(
      _ table: Row.Type,
      columns: (Row.TableColumns) -> (repeat each Column),
      conflict: Conflict
    ) throws {
      var names: [String] = []
      var binders: [SQLiteInsertBinder] = []
      var size = 0
      for column in repeat each columns(Row.columns) {
        binders.append(try sqliteArgumentBinder(for: column, after: &size))
        names.append(contentsOf: column._names)
      }
      // Reading an argument at the wrong offset would read memory as the wrong type, so the
      // layout worked out is checked against the one Swift reports, once, as the plan is built.
      precondition(
        size == MemoryLayout<(repeat (each Column).Value.QueryOutput)>.size,
        "An insert's arguments are not laid out as its plan expects."
      )
      try self.init(table, columnNames: names, binders: binders, conflict: conflict)
    }
  }

  // Binds a run's row to a plan's statement: a record, or a partial insert's arguments as one
  // tuple, lent by its address.
  //
  // The public entry points are inlined into their callers, which gather a run's values into a
  // tuple, and lend its address, in code specialized for the values' types. Code generic over a
  // parameter pack copies every value it steps through, and looks up the pack's tuple type, for
  // every row, which costs more than binding the values does, and Swift does not specialize a
  // step through a pack even where every type is known. Gathering a tuple it does specialize, to
  // a few stores. The plan, which is not generic, binds the row from its address.
  @usableFromInline
  struct SQLiteInsertArguments {
    // What a step of a bulk insert found: no element, the last one, or one with more after it.
    @usableFromInline
    enum Element {
      case none
      case last
      case more
    }

    private let plan: SQLiteInsertPlan
    private let library: UnsafePointer<SQLiteLibrary>

    // The statement a run binds, or `nil` when the SQL holds no statement, whose runs bind
    // nothing.
    private let statement: OpaquePointer?

    init(plan: SQLiteInsertPlan, library: UnsafePointer<SQLiteLibrary>, statement: OpaquePointer?) {
      self.plan = plan
      self.library = library
      self.statement = statement
    }

    // Binds the element `next` holds, as a bulk insert's step, and reads the one after it into
    // `next`, which is how the step tells the last element apart.
    @inlinable
    func bind<Elements: IteratorProtocol>(
      next: inout Elements.Element?,
      from iterator: inout Elements
    ) throws -> Element {
      guard let element = next else { return .none }
      next = iterator.next()
      try withUnsafePointer(to: element) { try bind(row: $0) }
      if case .none = next { return .last }
      return .more
    }

    // Binds the row at `row`, which must be of the type the plan was built for: the record, or
    // the tuple of a partial insert's arguments.
    @usableFromInline
    func bind(row: UnsafeRawPointer) throws {
      guard let statement else { return }
      var index: Int32 = 1
      for binder in plan.binders {
        index = try binder.bind(row + binder.offset, to: statement, at: index, library: library)
      }
    }
  }

  private func quoted(_ names: [String]) -> [QueryFragment] {
    names.map { "\(quote: $0)" }
  }

  // MARK: - Binders

  // Binds one of a run's values: a record, or one listed column's value. The value is lent by
  // address, typed by the plan that made the binder, so binding it copies nothing.
  class SQLiteInsertBinder {
    let parameterCount: Int

    // Where the value sits in a run's row: 0 for a record, or the value's offset in the tuple of
    // a partial insert's arguments.
    let offset: Int

    init(parameterCount: Int, offset: Int) {
      self.parameterCount = parameterCount
      self.offset = offset
    }

    // Binds the value at `value` from the parameter at `index` on, and returns the index of the
    // parameter after its last.
    func bind(
      _ value: UnsafeRawPointer,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws -> Int32 {
      fatalError("A subclass binds its values.")
    }
  }

  // Binds every column of a record from its own key path.
  final class SQLiteRecordBinder<Record>: SQLiteInsertBinder {
    let columns: [SQLiteColumnBinder<Record>]

    init(columns: [SQLiteColumnBinder<Record>], offset: Int) {
      self.columns = columns
      super.init(parameterCount: columns.count, offset: offset)
    }

    override func bind(
      _ value: UnsafeRawPointer,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws -> Int32 {
      let record = value.assumingMemoryBound(to: Record.self)
      var index = index
      for column in columns {
        try column.bind(record, to: statement, at: index, library: library)
        index += 1
      }
      return index
    }
  }

  // Binds one listed column's value, which the column's type binds as a single value.
  final class SQLiteValueBinder<Value: QueryBindable>: SQLiteInsertBinder {
    init(offset: Int) {
      super.init(parameterCount: 1, offset: offset)
    }

    override func bind(
      _ value: UnsafeRawPointer,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws -> Int32 {
      let output = value.assumingMemoryBound(to: Value.QueryOutput.self)
      try sqliteBind(
        Value(queryOutput: output.pointee).queryBinding,
        to: statement,
        at: index,
        library
      )
      return index + 1
    }
  }

  // Binds one listed column group's value, a column for each of the group's columns, as the
  // query builder renders a group's value.
  final class SQLiteGroupBinder<Group: Table>: SQLiteInsertBinder {
    let record: SQLiteRecordBinder<Group>

    init(record: SQLiteRecordBinder<Group>, offset: Int) {
      self.record = record
      super.init(parameterCount: record.parameterCount, offset: offset)
    }

    override func bind(
      _ value: UnsafeRawPointer,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws -> Int32 {
      let output = value.assumingMemoryBound(to: Group.QueryOutput.self)
      return try withUnsafePointer(to: Group(queryOutput: output.pointee)) { group in
        try record.bind(group, to: statement, at: index, library: library)
      }
    }
  }

  // Binds one column of a record.
  class SQLiteColumnBinder<Record> {
    func bind(
      _ record: UnsafePointer<Record>,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws {
      fatalError("A subclass binds its column.")
    }
  }

  // Reads a column stored in the record itself at its offset, which a key path to a stored
  // property of a struct reports, rather than walking the key path for every row.
  final class SQLiteStoredColumnBinder<Record, Member: QueryBindable>: SQLiteColumnBinder<Record> {
    let offset: Int

    init(offset: Int) {
      self.offset = offset
    }

    override func bind(
      _ record: UnsafePointer<Record>,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws {
      let value = UnsafeRawPointer(record).advanced(by: offset)
        .assumingMemoryBound(to: Member.QueryOutput.self)
      try sqliteBind(
        Member(queryOutput: value.pointee).queryBinding,
        to: statement,
        at: index,
        library
      )
    }
  }

  // Reads a column through its key path, converts it to the column's representation, and binds
  // that as the query builder would.
  final class SQLiteKeyPathColumnBinder<Record, Member: QueryBindable>:
    SQLiteColumnBinder<Record>
  {
    let keyPath: KeyPath<Record, Member.QueryOutput>

    init(keyPath: KeyPath<Record, Member.QueryOutput>) {
      self.keyPath = keyPath
    }

    override func bind(
      _ record: UnsafePointer<Record>,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws {
      let member = Member(queryOutput: record.pointee[keyPath: keyPath])
      try sqliteBind(member.queryBinding, to: statement, at: index, library)
    }
  }

  // A column whose key path starts from another type than the record it is bound from, which the
  // query builder casts the record to, as this does.
  final class SQLiteCastingColumnBinder<Record, Root, Member: QueryBindable>:
    SQLiteColumnBinder<Record>
  {
    let keyPath: KeyPath<Root, Member.QueryOutput>

    init(keyPath: KeyPath<Root, Member.QueryOutput>) {
      self.keyPath = keyPath
    }

    override func bind(
      _ record: UnsafePointer<Record>,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws {
      let member = Member(queryOutput: (record.pointee as! Root)[keyPath: keyPath])
      try sqliteBind(member.queryBinding, to: statement, at: index, library)
    }
  }

  // Opens a column once, extracting its key path, which a column builds anew each time it is
  // asked for one.
  private func sqliteColumnBinder<Record>(
    _ column: any TableColumnExpression,
    of record: Record.Type
  ) -> SQLiteColumnBinder<Record> {
    func open<Root, Member>(
      _ column: some TableColumnExpression<Root, Member>
    ) -> SQLiteColumnBinder<Record> {
      let keyPath = column.keyPath
      if let keyPath = keyPath as? KeyPath<Record, Member.QueryOutput> {
        if let offset = MemoryLayout<Record>.offset(of: keyPath) {
          return SQLiteStoredColumnBinder<Record, Member>(offset: offset)
        }
        return SQLiteKeyPathColumnBinder<Record, Member>(keyPath: keyPath)
      }
      return SQLiteCastingColumnBinder<Record, Root, Member>(keyPath: keyPath)
    }
    return open(column)
  }

  // The binder for a listed column's value: one value for a column, or one for each column of a
  // column group. Anything else, such as an optional column group, has no single value per
  // column, so it is refused.
  //
  // `size` is the size of the arguments before this one, as a tuple, and is left at the size
  // with this one. Swift lays a tuple out as it lays out a struct with the same fields, each at
  // the first offset after the one before it that suits its alignment, which is how the value's
  // offset is worked out.
  private func sqliteArgumentBinder<Column: _TableColumnExpression>(
    for column: Column,
    after size: inout Int
  ) throws -> SQLiteInsertBinder {
    typealias Argument = Column.Value.QueryOutput
    let alignment = MemoryLayout<Argument>.alignment
    let offset = (size + alignment - 1) / alignment * alignment
    size = offset + MemoryLayout<Argument>.size
    if let bindable = Column.Value.self as? any QueryBindable.Type {
      func open<Value: QueryBindable>(_: Value.Type) -> SQLiteInsertBinder {
        SQLiteValueBinder<Value>(offset: offset)
      }
      return open(bindable)
    }
    if let group = Column.Value.self as? any Table.Type {
      func open<Group: Table>(_: Group.Type) -> SQLiteInsertBinder {
        let columns = Group.TableColumns.allColumns.map { sqliteColumnBinder($0, of: Group.self) }
        return SQLiteGroupBinder(
          record: SQLiteRecordBinder(columns: columns, offset: 0),
          offset: offset
        )
      }
      return open(group)
    }
    let names = column._names.map { "\"\($0)\"" }.joined(separator: ", ")
    throw SQLiteError(
      code: .misuse,
      message: """
        an insert cannot bind \(names), of type \(Column.Value.self), as one value per column
        """
    )
  }

  @inline(__always)
  private func sqliteBind(
    _ binding: QueryBinding,
    to statement: OpaquePointer,
    at index: Int32,
    _ library: UnsafePointer<SQLiteLibrary>
  ) throws {
    try bind(
      OrbitDatabaseValue(lowering: binding),
      to: statement,
      at: index,
      library: library
    )
  }

  // MARK: - Plan cache

  // The plans the conveniences run, one for each table and conflict clause, kept for the life of
  // the process. A table's plan is always the same object, so its SQL is always the same string,
  // which is what lets the statement cache find its statement by identity.
  final class SQLiteInsertPlans: Sendable {
    private struct Key: Hashable {
      let table: ObjectIdentifier
      let conflict: UInt8
    }

    // Held by an object rather than in a static, since Swift 6.3 copies a noncopyable static as
    // it borrows it.
    private static let shared = SQLiteInsertPlans()

    private let plans = Lock([Key: SQLiteInsertPlan]())

    static func records<Row: Table>(
      _ table: Row.Type,
      onConflict conflict: SQLiteInsertConflict?
    ) throws -> SQLiteInsertPlan {
      try records(Row.self, code: conflict?.code ?? 0, conflict: conflict?.conflict ?? .none)
    }

    static func records<Row: Table>(
      _ table: Row.Type,
      onConflict conflict: SQLiteUpsertConflict<Row>
    ) throws -> SQLiteInsertPlan {
      try records(Row.self, code: conflict.code, conflict: conflict.conflict)
    }

    // `code` tells the conflict clauses apart, so that a clause is only worked out, which for an
    // update reads the table's primary key, when its plan is built.
    private static func records<Row: Table>(
      _ table: Row.Type,
      code: UInt8,
      conflict: @autoclosure () -> SQLiteInsertPlan.Conflict
    ) throws -> SQLiteInsertPlan {
      let key = Key(table: ObjectIdentifier(Row.self), conflict: code)
      let shared = Self.shared
      if let plan = shared.plans.withLock({ $0[key] }) { return plan }
      // Built outside the lock, since building reads the table's columns, which could take long
      // enough to hold up other tables' inserts. Two threads may build the same plan at once, and
      // the first one stored is the one both use.
      let plan = try SQLiteInsertPlan(records: Row.self, conflict: conflict())
      return shared.plans.withLock { plans in
        if let stored = plans[key] { return stored }
        plans[key] = plan
        return plan
      }
    }
  }

  // MARK: - Running

  // Runs an insert that may skip or update a row instead, and returns the rowid it inserted, or
  // `nil` when it inserted none.
  //
  // SQLite leaves the last inserted rowid as it was when an upsert skips a row or updates one, and
  // reports one changed row for an update as for an insert, so neither tells them apart. The
  // rowid is set to a value no insert reports before the run instead, and put back when the run
  // inserted nothing, so the connection reports what SQLite alone would have.
  func sqliteInsertedRowID(
    on connection: OpaquePointer,
    library: UnsafePointer<SQLiteLibrary>,
    by run: () throws -> Void
  ) throws -> Int64? {
    let connections = library.pointee.connections
    let previous = connections.lastInsertedRowID(connection)
    guard let setLastInsertedRowID = connections.setLastInsertedRowID else {
      // Without a way to set it, an unchanged rowid is taken to mean nothing was inserted, which
      // misses an insert whose rowid happens to equal the one reported before it.
      try run()
      let rowID = connections.lastInsertedRowID(connection)
      return connections.changes(connection) > 0 && rowID != previous ? rowID : nil
    }
    // Int64.min is a rowid only when a caller writes it explicitly, which a run would report as no
    // insert.
    setLastInsertedRowID(connection, .min)
    do {
      try run()
    } catch {
      setLastInsertedRowID(connection, previous)
      throw error
    }
    let rowID = connections.lastInsertedRowID(connection)
    guard rowID != .min else {
      setLastInsertedRowID(connection, previous)
      return nil
    }
    return rowID
  }

  extension SQLitePreparedStatement {
    var changesCount: Int {
      Int(library.pointee.connections.changes(connection))
    }

    var lastInsertedRowID: Int64 {
      library.pointee.connections.lastInsertedRowID(connection)
    }

    // Runs the insert once with the row at `row`: the record, or the tuple of a partial insert's
    // arguments.
    mutating func runInsert(_ plan: SQLiteInsertPlan, row: UnsafeRawPointer) throws {
      try SQLiteInsertArguments(plan: plan, library: library, statement: beginRun()).bind(row: row)
      try runToCompletion()
    }

    mutating func runUpsert(_ plan: SQLiteInsertPlan, row: UnsafeRawPointer) throws -> Int64? {
      try sqliteInsertedRowID(on: connection, library: library) {
        try runInsert(plan, row: row)
      }
    }

    // Runs the insert once for each element `step` binds, all or none, and returns the sum of
    // the rows each run changed.
    //
    // One statement is atomic on its own, so a single element runs as it is. More are run inside
    // a savepoint, released after the last and rolled back to when any fails, so that a failure
    // caught inside the transaction leaves none of the elements behind, while what the
    // transaction wrote before stays. The savepoint statements are kept compiled by the
    // connection, as its transaction statements are, since compiling and finalizing them would
    // cost as much as several rows.
    //
    // `step` binds the next element and says whether another follows it, which the caller knows
    // by reading one element ahead, so that a single element is run without a savepoint. The
    // elements come from a closure rather than a sequence, so that the public entry points,
    // which are inlined into their callers, step the caller's sequence and bind its elements in
    // code specialized for them. Code generic over the sequence steps it through its protocol,
    // which for a lazy one allocates for every element.
    mutating func runInserts(
      _ plan: SQLiteInsertPlan,
      each step: (SQLiteInsertArguments) throws -> SQLiteInsertArguments.Element
    ) throws -> Int {
      switch try step(SQLiteInsertArguments(plan: plan, library: library, statement: beginRun())) {
      case .none:
        return 0
      case .last:
        try runToCompletion()
        return changesCount
      case .more:
        break
      }
      try statements.execute(.beginBulkInsert)
      do {
        try runToCompletion()
        var count = changesCount
        while true {
          let element = try step(
            SQLiteInsertArguments(plan: plan, library: library, statement: beginRun())
          )
          if case .none = element { break }
          try runToCompletion()
          count += changesCount
          if case .last = element { break }
        }
        try statements.execute(.endBulkInsert)
        return count
      } catch {
        // The original failure is what the caller needs. Either of these can only fail where the
        // transaction itself is going away, as when the database is suspended.
        try? statements.execute(.undoBulkInsert)
        try? statements.execute(.endBulkInsert)
        throw error
      }
    }
  }
#endif
