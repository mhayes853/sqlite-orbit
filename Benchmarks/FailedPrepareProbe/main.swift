import SQLiteOrbit

// Fetches statements that fail to prepare through every spelling of the generic fetch path, and
// exits nonzero unless each one throws a SQLiteError.

struct Record: ConvertibleFromOrbitDatabaseRow {
  var id: Int

  init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(
    orbitDatabaseRow row: borrowing Row
  ) throws {
    id = try row[0, as: Int.self]
  }
}

func fetchGenerically<Transaction>(
  _ sql: SQL,
  in transaction: borrowing Transaction
) throws -> [Record]
where Transaction: OrbitDatabaseReadTransaction & ~Copyable & ~Escapable {
  try transaction.fetchAll(sql, as: Record.self)
}

let failingSQL: [SQL] = [
  "SELEC 1",
  "SELECT * FROM missing_table",
  "SELECT missing_column FROM items"
]

var owner = try SQLiteConnection(path: ":memory:", configuration: .default)
try owner.withWriteConnection { connection in
  try connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
  try connection.execute("INSERT INTO items VALUES (1), (2)")
}
var thrown = 0
var attempts = 0
for sql in failingSQL {
  try owner.withReadConnection { connection in
    try connection.transaction { transaction in
      attempts += 3
      do { _ = try transaction.fetchAll(sql, as: Record.self) } catch is SQLiteError { thrown += 1 }
      do { _ = try transaction.fetchAll(sql) { try $0[0, as: Int.self] } } catch is SQLiteError {
        thrown += 1
      }
      do { _ = try fetchGenerically(sql, in: transaction) } catch is SQLiteError { thrown += 1 }
    }
  }
}
let fetched = try owner.withReadConnection { connection in
  try connection.transaction { transaction in
    try transaction.fetchAll("SELECT id FROM items ORDER BY id", as: Record.self)
  }
}
print(
  "\(thrown) of \(attempts) failing fetches threw SQLiteError; then fetched \(fetched.map(\.id))"
)
struct ProbeFailure: Error {}
if thrown != attempts || fetched.map(\.id) != [1, 2] { throw ProbeFailure() }
