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

    // What binds each value a run is given, in order: a record insert's one record, or a
    // partial insert's one value per listed column.
    let slots: SQLiteInsertSlots

    var parameterCount: Int { slots.parameterCount }

    // Builds the SQL Structured Queries renders for `INSERT INTO <table> (<columns>) VALUES (…)`
    // with `conflict`, with a parameter in place of each value.
    init<Row: Table>(
      _ table: Row.Type,
      columnNames: [String],
      slots: consuming SQLiteInsertSlots,
      conflict: Conflict
    ) throws {
      let parameterCount = slots.parameterCount
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
      self.slots = slots
    }

    // A plan that writes every writable column of a record or draft, generated columns aside, as
    // `Table.insert { row }` does.
    convenience init<Row: Table>(records table: Row.Type, conflict: Conflict) throws {
      let columns = Row.TableColumns.writableColumns
      var names: [String] = []
      names.reserveCapacity(columns.count)
      var slots = SQLiteInsertSlotList()
      for column in columns {
        names.append(column.name)
        slots.appendColumn(column, of: Row.self)
      }
      try self.init(table, columnNames: names, slots: SQLiteInsertSlots(slots), conflict: conflict)
    }

    // A plan that writes only the listed columns, each from a run's argument, as
    // `Table.insert { ($0.a, $0.b) } values: { (a, b) }` does.
    //
    // A run is handed its arguments as one tuple, so each argument is read at its offset in the
    // tuple. Swift lays a tuple out as it lays out a struct with the same fields, each at the
    // first offset after the one before it that suits its alignment, which is how the offsets
    // are worked out.
    convenience init<Row: Table, each Column: _TableColumnExpression>(
      _ table: Row.Type,
      columns: (Row.TableColumns) -> (repeat each Column),
      conflict: Conflict
    ) throws {
      var names: [String] = []
      var slots = SQLiteInsertSlotList()
      for column in repeat each columns(Row.columns) {
        try slots.appendArgument(for: column)
        names.append(contentsOf: column._names)
      }
      // Reading an argument at the wrong offset would read memory as the wrong type, so the
      // layout worked out is checked against the one Swift reports, once, as the plan is built.
      precondition(
        slots.argumentsSize == MemoryLayout<(repeat (each Column).Value.QueryOutput)>.size,
        "An insert's arguments are not laid out as its plan expects."
      )
      try self.init(table, columnNames: names, slots: SQLiteInsertSlots(slots), conflict: conflict)
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

    // The plan's slots, which the run that makes these arguments keeps alive by holding the plan.
    private let slots: UnsafeBufferPointer<SQLiteInsertSlot>
    private let library: UnsafePointer<SQLiteLibrary>
    private var statement: OpaquePointer?

    init(plan: SQLiteInsertPlan, library: UnsafePointer<SQLiteLibrary>) {
      self.slots = plan.slots.buffer
      self.library = library
    }

    // Readies the arguments for a run of `statement`, or for none when the SQL holds no
    // statement, whose runs bind nothing.
    mutating func begin(_ statement: OpaquePointer?) {
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
      _ = try SQLiteInsertSlots.bind(slots, row: row, from: 1, to: statement, library: library)
    }
  }

  private func quoted(_ names: [String]) -> [QueryFragment] {
    names.map { "\(quote: $0)" }
  }

  // MARK: - Slots

  // One parameter a run binds, or one binder that binds one or more, read from a value at
  // `offset` bytes into the value a run is given.
  //
  // A column whose representation is one of the common built-in types is bound straight from
  // memory with SQLite's own bind function for it, which skips converting the stored value to
  // its representation, then to a `QueryBinding`, and then to an `OrbitDatabaseValue`, the three
  // steps that cost the most of a row's binds. Each binds exactly what those steps would.
  // Anything else, such as a custom representation, is bound by a binder through those steps.
  struct SQLiteInsertSlot {
    enum Kind: UInt8 {
      case int
      case int8
      case int16
      case int32
      case int64
      case uint8
      case uint16
      case uint32
      case bool
      case double
      case float
      case text
      case blob
      case binder
    }

    var offset: Int

    // Held without a retain, since the slots own their binders, so that a run touches no
    // reference count to reach one.
    var binder: Unmanaged<SQLiteInsertBinder>?

    var kind: Kind

    // Whether the value is an `Optional` of the kind's type, which binds `NULL` for `nil`.
    var isOptional: Bool

    // The kind for a representation bound straight from memory, or `nil` for one only a binder
    // binds. The representation is matched exactly, so a type that merely stores a built-in,
    // such as a tagged or JSON one, still goes through its own binding.
    static func primitive<Member: QueryBindable>(_: Member.Type) -> (Kind, isOptional: Bool)? {
      // A built-in type reads its stored value as itself, which is what lets it be read from
      // memory as the type it is.
      guard Member.QueryOutput.self == Member.self else { return nil }
      for (type, optionalType, kind) in primitives {
        if Member.self == type { return (kind, false) }
        if Member.self == optionalType { return (kind, true) }
      }
      return nil
    }

    // Read only when a plan is built. UInt64 is left to its binder, which refuses a value too
    // large for SQLite's integers.
    private static var primitives: [(Any.Type, Any.Type, Kind)] {
      [
        (Int.self, Int?.self, .int),
        (Int64.self, Int64?.self, .int64),
        (String.self, String?.self, .text),
        (Double.self, Double?.self, .double),
        (Bool.self, Bool?.self, .bool),
        ([UInt8].self, [UInt8]?.self, .blob),
        (Int32.self, Int32?.self, .int32),
        (Int16.self, Int16?.self, .int16),
        (Int8.self, Int8?.self, .int8),
        (UInt32.self, UInt32?.self, .uint32),
        (UInt16.self, UInt16?.self, .uint16),
        (UInt8.self, UInt8?.self, .uint8),
        (Float.self, Float?.self, .float)
      ]
    }

    @inline(__always)
    func bind(
      _ base: UnsafeRawPointer,
      index: inout Int32,
      to statement: OpaquePointer,
      library: UnsafePointer<SQLiteLibrary>
    ) throws {
      let value = base + offset
      let index32 = index
      let code: Int32
      switch kind {
      case .binder:
        index = try binder.unsafelyUnwrapped._withUnsafeGuaranteedRef {
          try $0.bind(value, to: statement, at: index32, library: library)
        }
        return
      case .int:
        code = bindInteger(read(Int.self, value), index32, statement, library)
      case .int8:
        code = bindInteger(read(Int8.self, value), index32, statement, library)
      case .int16:
        code = bindInteger(read(Int16.self, value), index32, statement, library)
      case .int32:
        code = bindInteger(read(Int32.self, value), index32, statement, library)
      case .int64:
        code = bindInteger(read(Int64.self, value), index32, statement, library)
      case .uint8:
        code = bindInteger(read(UInt8.self, value), index32, statement, library)
      case .uint16:
        code = bindInteger(read(UInt16.self, value), index32, statement, library)
      case .uint32:
        code = bindInteger(read(UInt32.self, value), index32, statement, library)
      case .bool:
        // The query builder binds a Bool as `.bool`, which is lowered to the integer 1 or 0.
        code = bindInteger(read(Bool.self, value).map { $0 ? 1 : 0 }, index32, statement, library)
      case .double:
        code = bindReal(read(Double.self, value), index32, statement, library)
      case .float:
        // The query builder widens a Float to a Double, as this does.
        code = bindReal(read(Float.self, value).map(Double.init), index32, statement, library)
      case .text:
        if let string = read(String.self, value) {
          code = bindText(string, to: statement, at: index32, library: library)
        } else {
          code = library.pointee.bindings.null(statement, index32)
        }
      case .blob:
        if let bytes = read([UInt8].self, value) {
          code = bindBlob(bytes, to: statement, at: index32, library: library)
        } else {
          code = library.pointee.bindings.null(statement, index32)
        }
      }
      try checkBound(code)
      index = index32 + 1
    }

    @inline(__always)
    private func read<T>(_: T.Type, _ value: UnsafeRawPointer) -> T? {
      isOptional
        ? value.assumingMemoryBound(to: T?.self).pointee
        : value.assumingMemoryBound(to: T.self).pointee
    }
  }

  @inline(__always)
  private func bindInteger(
    _ value: (some BinaryInteger)?,
    _ index: Int32,
    _ statement: OpaquePointer,
    _ library: UnsafePointer<SQLiteLibrary>
  ) -> Int32 {
    guard let value else { return library.pointee.bindings.null(statement, index) }
    return library.pointee.bindings.int64(statement, index, Int64(value))
  }

  @inline(__always)
  private func bindReal(
    _ value: Double?,
    _ index: Int32,
    _ statement: OpaquePointer,
    _ library: UnsafePointer<SQLiteLibrary>
  ) -> Int32 {
    guard let value else { return library.pointee.bindings.null(statement, index) }
    return library.pointee.bindings.double(statement, index, value)
  }

  // The slots of a plan or column group as they are worked out, before they are laid out for
  // runs.
  struct SQLiteInsertSlotList {
    fileprivate var slots: [SQLiteInsertSlot] = []
    fileprivate var binders: [SQLiteInsertBinder] = []
    fileprivate var parameterCount = 0

    // The size of a partial insert's arguments, as a tuple, so far.
    fileprivate(set) var argumentsSize = 0

    // A value whose representation is `Member`, stored at `offset`.
    mutating func appendValue<Member: QueryBindable>(_: Member.Type, at offset: Int) {
      if let (kind, isOptional) = SQLiteInsertSlot.primitive(Member.self) {
        slots.append(SQLiteInsertSlot(offset: offset, kind: kind, isOptional: isOptional))
        parameterCount += 1
      } else {
        appendBinder(SQLiteValueBinder<Member>(), at: offset)
      }
    }

    mutating func appendBinder(_ binder: SQLiteInsertBinder, at offset: Int) {
      binders.append(binder)
      slots.append(
        SQLiteInsertSlot(
          offset: offset,
          binder: Unmanaged.passUnretained(binder),
          kind: .binder,
          isOptional: false
        )
      )
      parameterCount += binder.parameterCount
    }

    // Opens a record's column once, extracting its key path, which a column builds anew each
    // time it is asked for one. A column stored in the record itself is read at its offset,
    // which a key path to a stored property of a struct reports, rather than walking the key
    // path for every row.
    mutating func appendColumn<Record>(_ column: any TableColumnExpression, of _: Record.Type) {
      func open<Root, Member>(_ column: some TableColumnExpression<Root, Member>) {
        let keyPath = column.keyPath
        if let keyPath = keyPath as? KeyPath<Record, Member.QueryOutput> {
          if let offset = MemoryLayout<Record>.offset(of: keyPath) {
            appendValue(Member.self, at: offset)
          } else {
            appendBinder(SQLiteKeyPathColumnBinder<Record, Member>(keyPath: keyPath), at: 0)
          }
        } else {
          appendBinder(SQLiteCastingColumnBinder<Record, Root, Member>(keyPath: keyPath), at: 0)
        }
      }
      open(column)
    }

    // A listed column's value: one value for a column, or one for each column of a column
    // group. Anything else, such as an optional column group, has no single value per column, so
    // it is refused.
    mutating func appendArgument<Column: _TableColumnExpression>(for column: Column) throws {
      typealias Argument = Column.Value.QueryOutput
      let alignment = MemoryLayout<Argument>.alignment
      let offset = (argumentsSize + alignment - 1) / alignment * alignment
      if let bindable = Column.Value.self as? any QueryBindable.Type {
        func open<Value: QueryBindable>(_: Value.Type) {
          appendValue(Value.self, at: offset)
        }
        open(bindable)
      } else if let group = Column.Value.self as? any Table.Type {
        func open<Group: Table>(_: Group.Type) {
          var columns = SQLiteInsertSlotList()
          for column in Group.TableColumns.allColumns {
            columns.appendColumn(column, of: Group.self)
          }
          appendBinder(SQLiteGroupBinder<Group>(columns: SQLiteInsertSlots(columns)), at: offset)
        }
        open(group)
      } else {
        let names = column._names.map { "\"\($0)\"" }.joined(separator: ", ")
        throw SQLiteError(
          code: .misuse,
          message: """
            an insert cannot bind \(names), of type \(Column.Value.self), as one value per column
            """
        )
      }
      argumentsSize = offset + MemoryLayout<Argument>.size
    }
  }

  // The slots a run walks, laid out in memory of their own, so that walking them retains
  // nothing, as walking an array of them, or of binder objects, would for each row.
  struct SQLiteInsertSlots: ~Copyable {
    private let slots: UnsafeMutableBufferPointer<SQLiteInsertSlot>

    // Keeps the binders alive, which the slots reference without retaining.
    private let binders: [SQLiteInsertBinder]

    let parameterCount: Int

    init(_ list: SQLiteInsertSlotList) {
      slots = .allocate(capacity: list.slots.count)
      _ = slots.initialize(from: list.slots)
      binders = list.binders
      parameterCount = list.parameterCount
    }

    deinit {
      slots.deallocate()
    }

    var buffer: UnsafeBufferPointer<SQLiteInsertSlot> {
      UnsafeBufferPointer(slots)
    }

    // Binds every slot from the row at `row`, from the parameter at `index` on, and returns the
    // index of the parameter after the last.
    @inline(__always)
    static func bind(
      _ slots: UnsafeBufferPointer<SQLiteInsertSlot>,
      row: UnsafeRawPointer,
      from index: Int32,
      to statement: OpaquePointer,
      library: UnsafePointer<SQLiteLibrary>
    ) throws -> Int32 {
      var index = index
      for slot in slots {
        try slot.bind(row, index: &index, to: statement, library: library)
      }
      return index
    }
  }

  // MARK: - Binders

  // Binds a value no slot binds from memory: one in a custom representation, a column reached
  // through a key path, or a column group. The value is lent by address, typed by the plan that
  // made the binder, so binding it copies nothing.
  class SQLiteInsertBinder {
    let parameterCount: Int

    init(parameterCount: Int) {
      self.parameterCount = parameterCount
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

  // Binds a value stored as its representation's output, which the representation binds as a
  // single value, as the query builder would.
  final class SQLiteValueBinder<Value: QueryBindable>: SQLiteInsertBinder {
    init() {
      super.init(parameterCount: 1)
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
    let columns: SQLiteInsertSlots

    init(columns: consuming SQLiteInsertSlots) {
      let parameterCount = columns.parameterCount
      self.columns = columns
      super.init(parameterCount: parameterCount)
    }

    override func bind(
      _ value: UnsafeRawPointer,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws -> Int32 {
      let output = value.assumingMemoryBound(to: Group.QueryOutput.self)
      return try withUnsafePointer(to: Group(queryOutput: output.pointee)) { group in
        try SQLiteInsertSlots.bind(
          columns.buffer,
          row: UnsafeRawPointer(group),
          from: index,
          to: statement,
          library: library
        )
      }
    }
  }

  // Reads a record's column through its key path, converts it to the column's representation,
  // and binds that as the query builder would.
  final class SQLiteKeyPathColumnBinder<Record, Member: QueryBindable>: SQLiteInsertBinder {
    let keyPath: KeyPath<Record, Member.QueryOutput>

    init(keyPath: KeyPath<Record, Member.QueryOutput>) {
      self.keyPath = keyPath
      super.init(parameterCount: 1)
    }

    override func bind(
      _ value: UnsafeRawPointer,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws -> Int32 {
      let record = value.assumingMemoryBound(to: Record.self)
      let member = Member(queryOutput: record.pointee[keyPath: keyPath])
      try sqliteBind(member.queryBinding, to: statement, at: index, library)
      return index + 1
    }
  }

  // A record's column whose key path starts from another type than the record it is bound from,
  // which the query builder casts the record to, as this does.
  final class SQLiteCastingColumnBinder<Record, Root, Member: QueryBindable>: SQLiteInsertBinder {
    let keyPath: KeyPath<Root, Member.QueryOutput>

    init(keyPath: KeyPath<Root, Member.QueryOutput>) {
      self.keyPath = keyPath
      super.init(parameterCount: 1)
    }

    override func bind(
      _ value: UnsafeRawPointer,
      to statement: OpaquePointer,
      at index: Int32,
      library: UnsafePointer<SQLiteLibrary>
    ) throws -> Int32 {
      let record = value.assumingMemoryBound(to: Record.self)
      let member = Member(queryOutput: (record.pointee as! Root)[keyPath: keyPath])
      try sqliteBind(member.queryBinding, to: statement, at: index, library)
      return index + 1
    }
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

    // `code` tells the conflict clauses apart, so that a clause is only worked out, which for an
    // update reads the table's primary key, when its plan is built.
    static func records<Row: Table>(
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

    // Runs the insert once, as `execute(binding:)` runs a statement, with the row at `row`: the
    // record, or the tuple of a partial insert's arguments.
    mutating func runInsert(_ plan: SQLiteInsertPlan, row: UnsafeRawPointer) throws {
      var arguments = SQLiteInsertArguments(plan: plan, library: library)
      arguments.begin(beginRun())
      try arguments.bind(row: row)
      try runBound()
    }

    mutating func runUpsert(_ plan: SQLiteInsertPlan, row: UnsafeRawPointer) throws -> Int64? {
      try sqliteInsertedRowID(on: connection, library: library) {
        try runInsert(plan, row: row)
      }
    }

    // Steps a run whose values are bound to completion.
    private mutating func runBound() throws {
      try withOrbitCursor(runCursor()) { cursor in
        while try cursor.next() != nil {}
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
      var arguments = SQLiteInsertArguments(plan: plan, library: library)
      arguments.begin(beginRun())
      switch try step(arguments) {
      case .none:
        return 0
      case .last:
        try runBound()
        return changesCount
      case .more:
        break
      }
      try statements.execute(.beginBulkInsert)
      do {
        try runBound()
        var count = changesCount
        while true {
          arguments.begin(beginRun())
          let element = try step(arguments)
          if case .none = element { break }
          try runBound()
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
