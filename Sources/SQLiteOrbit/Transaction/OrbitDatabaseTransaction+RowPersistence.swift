extension OrbitDatabaseWriteTransaction where Self: ~Copyable, Self: ~Escapable {
  /// Inserts assigned columns and decodes the complete record from `RETURNING *`.
  ///
  /// Unset columns are omitted, allowing database defaults and generated IDs. Swift property
  /// defaults are not used. Explicit NULL remains NULL. Constraint and decoding errors propagate;
  /// if the transaction body throws, its writes roll back. Returned values do not include later
  /// changes made by AFTER triggers. The database must support SQLite's RETURNING syntax.
  public borrowing func insert<Record: PersistableOrbitDatabaseRow>(
    _ values: OrbitDatabaseRowValues<Record>
  ) throws -> Record {
    let write = try RowWrite(values)
    guard let record = try fetchOne("\(write.insertSQL) RETURNING *", asRow: Record.self) else {
      throw OrbitDatabaseRowPersistenceError.noInsertedRow
    }
    return record
  }

  /// Builds typed insertion values and returns the complete database-assigned record.
  public borrowing func insert<Record: PersistableOrbitDatabaseRow>(
    _ type: Record.Type,
    values: (inout OrbitDatabaseRowValues<Record>) throws -> Void
  ) throws -> Record {
    var insertion = OrbitDatabaseRowValues<Record>()
    try values(&insertion)
    return try insert(insertion)
  }

  /// Inserts a complete record, including its supplied identity, and returns the stored values.
  @discardableResult
  public borrowing func insert<Record: PersistableOrbitDatabaseRow>(
    _ record: Record
  ) throws -> Record {
    try insert(encodedValues(record))
  }

  /// Updates one complete primary key, returning whether the statement updated a row.
  ///
  /// By default all encoded non-key columns are assigned. Explicit column lists cannot include
  /// primary keys, duplicate columns, unsupported properties, or unencoded values. Empty updates
  /// throw. Matching a record counts even if the assigned values equal its existing values.
  @discardableResult
  public borrowing func update<Record: PersistableOrbitDatabaseRow>(
    _ record: Record,
    columns: [PartialKeyPath<Record>]? = nil
  ) throws -> Bool {
    let write = try RowWrite(encodedValues(record))
    let keys = try write.identity(Record.orbitPrimaryKeyColumns)
    let updates = try write.assignments(columns, excluding: keys.map(\.name))
    guard !updates.isEmpty else { throw OrbitDatabaseRowPersistenceError.emptyUpdate }
    let assignments: SQL = updates.map { "\(quote: $0.name) = \($0.value)" }
      .joined(separator: ", ")
    let predicate: SQL = keys.map { "\(quote: $0.name) = \($0.value)" }
      .joined(separator: " AND ")
    try execute("UPDATE \(quote: Record.orbitTableName) SET \(assignments) WHERE \(predicate)")
    return changesCount > 0
  }

  /// Inserts a complete record or updates it on a matching unique conflict target.
  ///
  /// The target defaults to the complete primary key. An explicit target must describe a UNIQUE
  /// constraint supported by SQLite's column conflict syntax; nullable alternate targets follow
  /// SQLite's conflict behavior. Default assignments exclude both
  /// primary keys and target columns. An empty assignment list uses DO NOTHING. Conversion and
  /// metadata errors are reported before executing SQL; unrelated constraint failures propagate.
  public borrowing func upsert<Record: PersistableOrbitDatabaseRow>(
    _ record: Record,
    onConflict columns: [PartialKeyPath<Record>]? = nil,
    updating updateColumns: [PartialKeyPath<Record>]? = nil
  ) throws {
    let write = try RowWrite(encodedValues(record))
    let targetNames = try columns.map { try write.names($0) } ?? Record.orbitPrimaryKeyColumns
    guard !targetNames.isEmpty else { throw OrbitDatabaseRowPersistenceError.missingPrimaryKey }
    let target = try write.selected(targetNames)
    if !Record.orbitPrimaryKeyColumns.isEmpty {
      _ = try write.identity(Record.orbitPrimaryKeyColumns)
    }
    let updates = try write.assignments(
      updateColumns,
      excluding: Record.orbitPrimaryKeyColumns + target.map(\.name)
    )
    let conflict: SQL = target.map { "\(quote: $0.name)" }.joined(separator: ", ")
    var sql: SQL = "\(write.insertSQL) ON CONFLICT (\(conflict))"
    if updates.isEmpty {
      sql.append(" DO NOTHING")
    } else {
      let assignments: SQL = updates.map { "\(quote: $0.name) = excluded.\(quote: $0.name)" }
        .joined(separator: ", ")
      sql.append(" DO UPDATE SET \(assignments)")
    }
    try execute(sql)
  }

  /// Saves a complete record by upserting on its primary key.
  public borrowing func save<Record: PersistableOrbitDatabaseRow>(_ record: Record) throws {
    try upsert(record)
  }
}

private func encodedValues<Record: ConvertibleToOrbitDatabaseRow>(
  _ record: Record
) throws -> OrbitDatabaseRowValues<Record> {
  var values = OrbitDatabaseRowValues<Record>()
  try record.encodeOrbitDatabaseRow(into: &values)
  return values
}

private struct RowWrite<Record: PersistableOrbitDatabaseRow> {
  typealias Column = (name: String, value: OrbitDatabaseValue)
  let columns: [Column]

  init(_ values: OrbitDatabaseRowValues<Record>) throws {
    self.columns = try values.encodedColumns()
  }

  var insertSQL: SQL {
    guard !columns.isEmpty else {
      return "INSERT INTO \(quote: Record.orbitTableName) DEFAULT VALUES"
    }
    let names: SQL = columns.map { "\(quote: $0.name)" }.joined(separator: ", ")
    let values: SQL = columns.map { "\($0.value)" }.joined(separator: ", ")
    return "INSERT INTO \(quote: Record.orbitTableName) (\(names)) VALUES (\(values))"
  }

  func names(_ keyPaths: [PartialKeyPath<Record>]) throws -> [String] {
    try keyPaths.map {
      guard let name = Record.orbitColumnName(for: $0) else {
        throw OrbitDatabaseRowPersistenceError.unknownColumn
      }
      return name
    }
  }

  func selected(_ names: [String]) throws -> [Column] {
    var result: [Column] = []
    for name in names {
      if result.contains(where: { matches($0.name, name) }) {
        throw OrbitDatabaseRowPersistenceError.duplicateColumn(name)
      }
      guard let column = columns.first(where: { matches($0.name, name) }) else {
        throw OrbitDatabaseRowPersistenceError.missingValue(name)
      }
      result.append(column)
    }
    return result
  }

  func identity(_ names: [String]) throws -> [Column] {
    guard !names.isEmpty else { throw OrbitDatabaseRowPersistenceError.missingPrimaryKey }
    let keys = try selected(names)
    for column in keys where column.value == .null {
      throw OrbitDatabaseRowPersistenceError.nullPrimaryKey(column.name)
    }
    return keys
  }

  func assignments(_ keyPaths: [PartialKeyPath<Record>]?, excluding names: [String]) throws
    -> [Column]
  {
    guard let keyPaths else {
      return columns.filter { column in !names.contains(where: { matches(column.name, $0) }) }
    }
    let assignments = try selected(self.names(keyPaths))
    for column in assignments where names.contains(where: { matches(column.name, $0) }) {
      throw OrbitDatabaseRowPersistenceError.identityUpdate(column.name)
    }
    return assignments.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
  }

  private func matches(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
  }
}
