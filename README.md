# sqlite-orbit

`sqlite-orbit` is a SQLite application framework for Swift: typed transactions, lazy cursors,
value observation, and cross-process coordination, so several processes can share one database
and react to each other's writes.

```swift
import SQLiteOrbit

let database = try OrbitDatabase(path: databasePath)

try await database.write { transaction in
  try transaction.execute(Reminder.insert { reminder })
}

for try await reminders in ValueObservation.tracking({ try $0.fetchAll(Reminder.all) })
  .values(in: database)
{
  render(reminders)
}
```

`SQLiteDatabaseReader` and `SQLiteDatabaseWriter` define the synchronous and asynchronous boundaries
around the native SQLite implementation, which lends distinct `SQLiteReadTransaction` and
`SQLiteWriteTransaction` values. Read transactions can only query, while write transactions can
query and execute mutations. Transactions and rows are nonescapable, so a database-owned SQLite
connection cannot outlive its access closure. `ValueObservation` builds callback and
asynchronous-sequence observation on that transaction boundary, both within one process and across
cooperating processes.

[swift-structured-queries](https://github.com/pointfreeco/swift-structured-queries) is the package's
query construction and binding layer, and `import SQLiteOrbit` re-exports it, so no second import is
needed to build statements. Statements can be executed and decoded directly by any read or write
transaction.

Whether a statement needs a write transaction is read off its type. A `DatabaseQuery<Access>` pairs
a statement with the capability it requires, and can only be built from a statement that already has
it: every `SELECT`-shaped statement can become a read query, and any statement at all can become a
write query. So a read transaction cannot be handed an `INSERT`, `UPDATE`, `DELETE`, or trigger
definition, and this is checked at compile time rather than by a list of known statement types.
Statements the query library keeps private, such as the one behind `union`, are classified too.

Raw SQL is the exception: its capability cannot be read from its type, so it is accepted by read and
write transactions alike, and the caller is stating which it is.

## Drivers

The package ships its own SQLite driver, which is the default and needs no third-party dependency:

```swift
import SQLiteOrbit

let database = try OrbitDatabase(path: databasePath)

try await database.write { transaction in
  try transaction.execute(Reminder.insert { reminder })
}

let reminders = try await database.read { transaction in
  try transaction.fetchAll(Reminder.all)
}
```

Two drivers back it:

- `SQLitePool` runs the database in WAL mode with one writer and a fixed set of readers.
  Reads run alongside one another; a write waits for the reads in flight and holds off the reads
  queued behind it, so a read issued after a write observes it. Waiting suspends rather than blocking
  a thread.
- `SQLiteQueue` serializes every access through a single connection. This is the driver for a
  `DatabasePath.memory` or `.temporary` database, which is private to the connection that opened it
  and so cannot be pooled at all.

Each connection runs on a dispatch queue of its own, so a query never occupies a cooperative-pool
thread.

A driver is opened with a `DatabasePath` rather than a string, so the databases that no second
connection can reach are named outright:

```swift
let onDisk = DatabasePath.file(url)         // or DatabasePath("/path/to/db.sqlite")
let inMemory = DatabasePath.memory          // ":memory:"
let scratch = DatabasePath.temporary        // ""
```

A file path resolves to an absolute path, so the same database is the same `DatabasePath` however
it was spelled. String literals convert, so `try SQLiteQueue(path: ":memory:")` still reads
the way it always did.

## Using your own SQLite build

The core module imports no SQLite header. Every call goes through `SQLiteLibrary`, a struct of
closures bound to SQLite's entry points, so the package can drive a build it was never linked
against — SQLCipher, a custom amalgamation, or one with extensions compiled in:

```swift
var library = SQLiteLibrary.system
library.open_v2 = myBuild.open_v2
// ...or build the whole table from your own module's symbols.

var configuration = SQLiteConfiguration(library: library)
let database = try OrbitDatabase(path: databasePath, configuration: configuration)
```

`SQLiteLibrary.system` is vended by the `SystemSQLite` trait, which is enabled by default. Disabling
it links no SQLite at all, leaving the library entirely to you:

```swift
.package(
  url: "https://github.com/your-org/sqlite-orbit",
  from: "0.1.0",
  traits: []
)
```

Because each member is an ordinary closure, a single entry point can be wrapped without disturbing
the rest — counting statement preparations, or injecting `SQLITE_BUSY` to test how code behaves
under contention.

A transaction also exposes the raw connection and the library it belongs to, for work the package
does not model:

```swift
try await database.read { transaction in
  let library = transaction.sqlite
  var statement: OpaquePointer?
  _ = "SELECT 1".withCString {
    library.prepare_v3(transaction.sqliteConnection, $0, -1, 0, &statement, nil)
  }
  defer { _ = library.finalize(statement) }
  // ...
}
```

Statements come in four shapes, and `fetchAll`, `fetchOne`, and `fetchCursor` cover all of them: a
single projected value, a tuple of projected values, an unprojected select decoding to its table,
and a select with joins decoding to a tuple of every table in the row.

```swift
try await database.read { transaction in
  try transaction.fetchAll(Reminder.select(\.title))                  // [String]
  try transaction.fetchAll(Reminder.select { ($0.id, $0.title) })      // [(Int, String)]
  try transaction.fetchAll(Reminder.all)                               // [Reminder]

  try transaction.fetchAll(                                            // [(Reminder, RemindersList)]
    Reminder.join(RemindersList.all) { $0.listID.eq($1.id) }
  )

  try transaction.fetchCount(Reminder.where { !$0.isCompleted })
  try transaction.find(Reminder.all, key: 42)  // throws DatabaseRecordNotFoundError
}
```

Write transactions perform every read operation in addition to mutations, and can fetch the rows a
statement returns:

```swift
let titles = try await database.write { transaction in
  try transaction.fetchAll(
    Reminder.update { $0.isCompleted = true }
      .where { $0.listID.eq(listID) }
      .returning(\.title)
  )
}
```

When a column does not decode, the failure is a `DatabaseColumnDecodingError` naming the column's
index and name, the storage class actually found, and the statement's SQL.

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

## Collations and functions

Collating sequences and functions written in Swift are declared with the `@DatabaseCollation` and
`@DatabaseFunction` macros, then registered on a `SQLiteConfiguration`:

```swift
@DatabaseCollation
func localized(_ lhs: String, _ rhs: String) -> CollationOrder {
  CollationOrder(lhs.localizedCompare(rhs))
}

extension Collation where Self == NamedCollation {
  static var localized: Self { Self($localized) }
}

var configuration = SQLiteConfiguration.default
configuration.register(collation: $localized)

let database = try OrbitDatabase(
  path: databasePath,
  configuration: configuration
)

let reminders = try await database.read { transaction in
  try transaction.fetchAll(Reminder.order { $0.title.collate(.localized) })
}
```

Register through the configuration rather than installing on a connection directly. A collation or
function is only known to the connection it was installed on. The native pool owns several
connections, so installing on one directly would leave queries on every other connection failing
with "no such collation sequence".

These typed registration helpers are available with `SystemSQLite`, because their static C
callbacks must use the same SQLite ABI as the connection. With a fully caller-supplied SQLite
build, register callbacks through that build's API using the transaction's raw connection instead.

`OrbitDatabase` is `Identifiable`. Its native writer supplies the default database
identifier, and callers can override it when constructing the database. File databases derive a
stable identifier from their absolute paths; a database private to its connection is not the same
database as any other, so each one receives a unique identifier.

## Observation

`SQLiteQueue`, `SQLitePool`, and `OrbitDatabase` are observable databases. A
value observation fetches an initial value, then fetches again after every committed write:

```swift
let reminders = ValueObservation.tracking { transaction in
  try transaction.fetchAll(Reminder.all)
}

for try await reminders in reminders.values(in: database) {
  render(reminders)
}
```

Use `changes(in:)` when the reason for each fetch matters. An initial fetch has an `.initial`
source; a committed transaction reports whether it came from this process or another one:

```swift
for try await change in reminders.changes(in: database) {
  switch change.source {
  case .initial:
    initialize(with: change.value)
  case .transaction(.local):
    updateFromLocalWrite(change.value)
  case .transaction(.external):
    updateFromExternalWrite(change.value)
  }
}
```

Both sequences start observing when iteration begins, and buffer every element a slow consumer has
not taken yet. Pass a `bufferingPolicy` to bound that buffer, which lets a slow loop skip ahead to
the current state of the database rather than working through every intermediate one:

```swift
for try await change in reminders.changes(in: database, bufferingPolicy: .bufferingNewest(1)) {
  await render(change)
}
```

The callback API is the primitive beneath both asynchronous sequences:

```swift
let subscription = try reminders.subscribe(
  to: database,
  onError: report,
  onChange: { change in render(change.value) }
)
```

Retain the returned `OrbitSubscription` for as long as changes should be delivered. Multiple
subscribers to the same observation and database share one fetch. Observations support ordered,
non-terminal transformations after each database fetch has ended:

```swift
let titles = reminders
  .filter { !$0.isEmpty }
  .compactMap { $0.first?.title }
  .map { $0.uppercased() }
  .removeDuplicates()
```

`filter` and `compactMap` suppress individual values without ending the observation. A thrown
operator error ends it. Operators run in their written order, and every emitted change keeps the
source metadata of the fetched value. `removeDuplicates(by:)` accepts a custom comparison.

`handleEvents` traces what an observation is doing without changing what it produces, which is the
way to check that a chain is not fetching more often than it needs to:

```swift
let traced = reminders.handleEvents(
  willFetch: { fetchCount.withLock { $0 += 1 } },
  didReceiveValue: { logger.debug("\($0.count) reminders") }
)
```

`didReceiveValue` observes values at that operator's position in the chain, so an upstream `filter`
or `removeDuplicates` hides the values it suppressed. The remaining callbacks belong to the runtime
that subscribers share, not to any one subscriber: `willStart` runs for the fetch the first
subscriber triggers, and `didCancel` runs once the last subscriber goes away. Since a local write
is fetched inside its own transaction, `willFetch` precedes the `databaseDidChange` for that write;
every other fetch follows the commit that prompted it.

Callback delivery is scheduled with Swift concurrency. The default `.async()` scheduler uses the
cooperative executor; `.async(on:)` targets an actor, and `.mainActor` is the main-actor spelling.
An actor scheduler delivers immediately when subscription already starts on that actor, including
its initial value. Starting elsewhere preserves callback order across the asynchronous hop.
`.immediate` introduces no scheduling boundary and performs the initial read before `subscribe`
returns:

```swift
let subscription = try reminders.subscribe(
  to: database,
  scheduling: .mainActor,
  onError: { @MainActor error in report(error) },
  onChange: { @MainActor change in render(change.value) }
)
```

On platforms with SwiftUI, main-actor schedulers can wrap deferred callbacks in a `Transaction` or
an `Animation` without importing a second package product:

```swift
let scheduler = MainActorValueObservationScheduler.mainActor.animation(.default)
let subscription = try reminders.subscribe(
  to: database,
  scheduling: scheduler,
  onError: { @MainActor error in report(error) },
  onChange: { @MainActor change in render(change.value) }
)
```

When the initial value is immediate, it is delivered directly and does not enter the SwiftUI
transaction; only scheduled callbacks do.

Use `filterTransactions(_:)` to avoid fetching for irrelevant commit notifications. The commit's
origin identifies whether the sender was this process or another one; the initial value is always
fetched:

```swift
let remoteReminders = reminders.filterTransactions { commit in
  commit.origin == .external
}
```

The predicate can also inspect the latest value accepted at that point in the operator chain. It is
`nil` until the first value is produced there, and values suppressed by an earlier operator do not
replace it:

```swift
let staleReminders = reminders.filterTransactions { commit, previousValue in
  commit.origin == .external || previousValue?.contains(where: \.isStale) == true
}
```

Local observations fetch their pending value through the write transaction and publish it only
after SQLite commits. A rollback, including a failed `COMMIT`, discards that value. External commit
announcements trigger a fresh read instead. Fetch failures end the callback subscription or
throwing asynchronous sequence; they never roll back the write whose final state was being fetched.

For transaction lifecycle events that do not produce a value, register a
`DatabaseTransactionObserver` directly with any `SQLiteObservableDatabase`. Its `databaseWillCommit`
hook receives a read-only view of the pending transaction and may throw to abort the write;
`databaseDidCommit` identifies the transaction's local or external origin.

## Cross-process transport

The package includes a public, configurable Unix-domain datagram transport. Processes that need to
communicate must use the same coordination directory and database identifier:

```swift
let transport = try UnixDatagramIPCTransport(
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

Retain the `OrbitSubscription` for as long as messages should be delivered. Cancelling it, or
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

`OrbitDatabase(path:)` owns opening the database, which is what lets it coordinate:

```swift
let database = try OrbitDatabase(path: databasePath)
```

The database is opened by `SQLitePool`, so it runs in WAL mode with concurrent readers and a
single writer, and every connection gets a busy timeout. Without one, a write that overlaps another
process's write fails outright rather than waiting its turn.

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
let database = try OrbitDatabase(
  path: databasePath,
  coordination: .init(directory: appGroupDirectory, backPressure: .suspend(upTo: .milliseconds(250)))
)
```

A database private to its connection cannot be shared between processes, or pooled, so
`SQLitePool` rejects one; use `SQLiteQueue` for those.

Constructing a driver yourself remains available for a database you configure and open on your own.
That cannot coordinate opening, so pass a transport explicitly if the database is also opened
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

An observed `OrbitDatabase` also subscribes to its peers. Incoming announcements are exposed
as external transaction events and cause active value observations to refetch.
