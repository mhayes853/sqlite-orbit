# swift-sqlite-cross

`swift-sqlite-cross` is a transaction and observation foundation for coordinating a SQLite
database across multiple processes.

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

## Cross-process transport

The package includes a public, configurable Unix-domain datagram transport. Processes that need to
communicate must use the same coordination directory and database identifier:

```swift
let transport = try UnixDatagramDatabaseIPCTransport(
  configuration: .init(
    directory: coordinationDirectory,
    backPressure: .suspend(upTo: .milliseconds(250))
  )
)

let databaseIdentifier = DatabaseIdentifier(rawValue: "example.sqlite")
let subscription = try transport.subscribe(to: databaseIdentifier) { message in
  switch message {
  case .transactionDidCommit:
    refreshObservations()
  @unknown default:
    break
  }
}

try await transport.send(
  .transactionDidCommit(.init(databaseIdentifier: databaseIdentifier))
)
```

Retain the `SQLiteCrossSubscription` for as long as messages should be delivered. Cancelling it, or
releasing its final copy, removes the process's registration when it has no other subscriber for
that database.

Delivery is bounded, at-most-once, and nondurable. Each send broadcasts to the peer processes that
are discoverable at that moment. A successful return means every discovered peer accepted the
message into its kernel receive queue, not that its handler has already run. No unbounded
user-space queue is used:

- `.fail` attempts every peer once and reports a `DatabaseIPCPartialDeliveryError` if any queue is
  full or another peer fails.
- `.suspend(upTo:)` retries only backpressured peers until the shared deadline, then reports partial
  delivery. Task cancellation also cancels the wait.

Messages use a private versioned binary envelope and are decoded from `Span`; callers exchange
`DatabaseIPCMessage` values rather than serialized `Data`. `DatabaseIPCMessage` is nonexhaustive so
the library can add coordination messages in future versions.

## Opening a database for several processes

`CrossProcessDatabase(path:)` owns opening the database, which is what lets it coordinate:

```swift
let database = try CrossProcessDatabase(path: databasePath)
```

The database is opened as a GRDB `DatabasePool`, so it runs in WAL mode with concurrent readers and
a single writer, and it uses `Configuration.crossProcess`, which gives SQLite a busy timeout. GRDB
reports `SQLITE_BUSY` immediately by default, so without that timeout any write that overlaps
another process's write fails outright rather than waiting its turn.

Opening is serialized across every process sharing a coordination directory by an exclusive advisory
lock, held only while the database is being opened. Moving a new database into WAL mode briefly
needs an exclusive lock of SQLite's own, so processes that first open the same database at the same
moment would otherwise contend for it. The lock removes that contention between opens; it does not
replace the busy timeout, since closing a WAL database checkpoints it under an exclusive lock too,
and closing is not something a database can hold the open lock across.

Processes coordinate only when they share a coordination directory. The default lives in the
temporary directory; sandboxed applications must supply one both processes can reach, such as an App
Group container:

```swift
let database = try CrossProcessDatabase(
  path: databasePath,
  coordination: .init(directory: appGroupDirectory, backPressure: .suspend(upTo: .milliseconds(250)))
)
```

`init(writer:)` remains available for a writer you configure and open yourself. It cannot coordinate
opening or guarantee a busy timeout, so pass a transport explicitly if that database is also opened
elsewhere.

## Announcing committed writes

A database announces every write transaction it commits:

```swift
try await database.write { transaction in
  try transaction.execute(Reminder.insert { reminder })
}
// Peers sharing the coordination directory have now been sent .transactionDidCommit.
```

The announcement is sent after the driver releases its write transaction, never inside it: a peer
told about a commit must be able to read it, and holding SQLite's write lock while waiting on a
backpressured peer would turn one stalled process into a stalled database.

By the time a write commits it is already durable, so a failed announcement never fails the write.
Pass `onAnnouncementFailure:` to observe those failures. Announcing is likewise shielded from the
writing task's cancellation, since peers still need to learn about a commit that happened. A write
that throws is rolled back by its driver and is not announced.

Databases do not yet subscribe to their peers. Announcing is one-way for now, and receiving will
arrive with observation, which is what gives an incoming announcement something to do.
