# swift-sqlite-cross

`swift-sqlite-cross` is a transaction and, eventually, observation layer for coordinating a
SQLite database across multiple processes.

The package currently focuses on its local transaction boundary. `DatabaseDriver` asynchronously
lends distinct `DatabaseReadTransaction` and `DatabaseWriteTransaction` values. Read transactions
can only query, while write transactions can query and execute mutations. Transactions and rows are
nonescapable, so a driver-owned SQLite connection cannot outlive its access closure.

[swift-structured-queries](https://github.com/pointfreeco/swift-structured-queries) is the package's
query construction and binding layer. Its statements can be executed and decoded directly by any
read or write transaction; the generic protocols have no dependency on GRDB types.

GRDB support is available in the main `SQLiteCross` product behind the `GRDB` package trait:

```swift
.package(
  url: "https://github.com/your-org/swift-sqlite-cross",
  from: "0.1.0",
  traits: ["GRDB"]
)
```

```swift
import GRDB
import SQLiteCross

let queue = try DatabaseQueue(path: databasePath)
let database = CrossProcessDatabase(
  driver: GRDBDatabaseDriver(writer: queue)
)

try await database.write { transaction in
  try transaction.execute(Reminder.insert { reminder })
}

let reminders = try await database.read { transaction in
  try transaction.fetchAll(Reminder.all)
}
```

For lazy reads, transactions expose a scoped cursor. The low-level `rowCursor` API lends raw rows;
`fetchCursor` decodes the statement's statically known output while advancing:

```swift
let reminders = try await database.read { transaction in
  var cursor = try transaction.fetchCursor(Reminder.all)
  var reminders: [Reminder] = []

  while let reminder = try cursor.next() {
    reminders.append(reminder)
  }

  return reminders
}
```

Cursors must be consumed inside the transaction that created them. Write transactions also expose
`executeCursor` for statements that return rows, such as SQLite `RETURNING` statements.

Typed cursors can be transformed lazily. Transformations consume their source cursor, so bind the
result when it will be advanced or passed to `forEach`:

```swift
let source = try transaction.fetchCursor(Reminder.all)
var titles = source
  .filter { !$0.isCompleted }
  .compactMap(\.title)
  .map { $0.uppercased() }

try titles.forEach { title in
  print(title)
}
```

To eagerly materialize a cursor, collect it into an array or another known collection type:

```swift
let titles = try transaction.fetchCursor(Reminder.all)
  .filter { !$0.isCompleted }
  .collect()

let uniqueTitles = try transaction.fetchCursor(Reminder.all)
  .map(\.title)
  .collect(as: Set<String>.self)

let incompleteCount = try transaction.fetchCursor(Reminder.all)
  .count { !$0.isCompleted }

let nextReminder = try transaction.fetchCursor(Reminder.all)
  .first { !$0.isCompleted }

let bounds = try transaction.fetchCursor(Reminder.all)
  .map(\.priority)
  .minMax()
```

Terminal operations consume the remaining cursor values. Operations such as `first`, `isEmpty`,
`contains`, and `allSatisfy` stop as soon as their result is known; reductions and `min`/`max`
visit every remaining value. `minMax` computes both extrema in one traversal.

`CrossProcessDatabase` is `Identifiable`. A driver supplies its default database identifier, and
callers can override it when constructing the database. The GRDB driver derives stable identifiers
for file databases from their standardized paths and unique identifiers for in-memory databases.

Cross-process IPC and observation are intentionally not implemented yet. They will be layered on
after this transaction API is settled.
