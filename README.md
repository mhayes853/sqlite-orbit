# sqlite-orbit

> [!IMPORTANT]
> This is entirely agent written and is mainly a prototype.

`sqlite-orbit` is a SQLite application framework for Swift: typed transactions, lazy cursors,
value observation, and cross-process coordination, so several processes can share one database
and react to each other's writes.

```swift
import SQLiteOrbit

let database = try OrbitDatabase(path: databasePath)

try await database.write { transaction in
  try transaction.execute(Reminder.insert { reminder })
}

for try await reminders in OrbitValueObservation.trackingAll(Reminder.all)
  .values(in: database)
{
  render(reminders)
}
```

`OrbitDatabaseReader` and `OrbitDatabaseWriter` define the synchronous and asynchronous boundaries
around the native SQLite implementation, which lends distinct `SQLiteReadTransaction` and
`SQLiteWriteTransaction` values. Read transactions can only query, while write transactions can
query and execute mutations. Transactions and rows are nonescapable, so a database-owned SQLite
connection cannot outlive its access closure. `OrbitValueObservation` builds callback and
asynchronous-sequence observation on that transaction boundary, both within one process and across
cooperating processes.

[swift-structured-queries](https://github.com/pointfreeco/swift-structured-queries) is the package's
query construction and binding layer, and `import SQLiteOrbit` re-exports it, so no second import is
needed to build statements. Statements can be executed and decoded directly by any read or write
transaction.

Whether a statement needs a write transaction is read off its type. An `OrbitDatabaseQuery<Access>`
pairs a statement with the capability it requires, and can only be built from a statement that
already has it: every `SELECT`-shaped statement can become a read query, and any statement at all
can become a write query. So a read transaction cannot be handed an `INSERT`, `UPDATE`, `DELETE`, or
trigger definition, and this is checked at compile time rather than by a list of known statement
types. Statements the query library keeps private, such as the one behind `union`, are classified
too.

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

Two ordinary SQLite drivers back it:

- `SQLitePool` runs the database in WAL mode with one writer and a fixed set of readers.
  Reads run alongside one another; a write waits for the reads in flight and holds off the reads
  queued behind it, so a read issued after a write observes it. Waiting suspends rather than
  blocking a thread.
- `SQLiteQueue` serializes every access through a single connection. This is the driver for an
  `OrbitDatabasePath.memory` or `.temporary` database, which is private to the connection that
  opened it and so cannot be pooled at all.

Each connection runs on a dispatch queue of its own, so a query never occupies a cooperative-pool
thread.

A driver is opened with an `OrbitDatabasePath` rather than a string, so the databases that no second
connection can reach are named outright:

```swift
let onDisk = OrbitDatabasePath.file(url)         // or OrbitDatabasePath("/path/to/db.sqlite")
let inMemory = OrbitDatabasePath.memory          // ":memory:"
let scratch = OrbitDatabasePath.temporary        // ""
```

A file path resolves to an absolute path, so the same database is the same `OrbitDatabasePath`
however it was spelled. String literals convert, so `try SQLiteQueue(path: ":memory:")` still reads
the way it always did.

## Using your own SQLite build

The core module imports no SQLite header. Every call goes through `SQLiteLibrary`. Its required
entry points are grouped by responsibility, including distinct statement preparation, execution,
and inspection APIs. Authorizers, trusted-schema control, scalar functions, aggregate functions,
collations, and encryption are independent optional operations. The package can therefore drive a
build it was never linked against — SQLCipher, a custom amalgamation, or one with extensions
compiled in:

```swift
let library = #sqliteLibrary(module: "MySQLite")

var configuration = SQLiteConfiguration(library: library)
let database = try OrbitDatabase(path: databasePath, configuration: configuration)
```

The macro takes a static `SQLiteLibrary.APIs` option set describing the symbols that module
exports. `.standard` is the default; add encryption for a module such as SQLCipher:

```swift
let library = #sqliteLibrary(module: "SQLCipher", apis: [.standard, .encryption])
```

The option set only controls macro expansion—it is not retained as runtime capability state. Code
checks the optional operation it needs. For example, a custom library can implement trusted-schema
control as a function over the same primitive connection access used by setup callbacks and
transactions:

```swift
library.trustedSchema = { connection, enabled in
  try connection.execute("PRAGMA trusted_schema = \(raw: enabled ? 1 : 0)")
}
```

`SQLiteConnectionAccess.execute` also accepts a `QueryFragment`, including safely bound values.

`SQLiteLibrary.system` is vended by the `SystemSQLite` trait, which is enabled by default. Disabling
it links no SQLite at all, leaving the library entirely to you:

```swift
.package(
  url: "https://github.com/your-org/sqlite-orbit",
  from: "0.1.0",
  traits: []
)
```

The `SQLCipher` trait links SQLCipher instead and vends `SQLiteLibrary.sqlCipher`. It is mutually
exclusive with `SystemSQLite`: SQLCipher is a fork of SQLite and exports the same `sqlite3_*`
symbols, so enabling both would link two builds under one set of names and leave the link order to
decide which one every call reaches. Naming any trait leaves the defaults out, which is what makes
the traits exclusive in practice:

```swift
.package(
  url: "https://github.com/your-org/sqlite-orbit",
  from: "0.1.0",
  traits: ["SQLCipher"]
)
```

The experimental `Turso` trait drives Turso's local Rust engine through its SQLite-compatible C
API and vends `SQLiteLibrary.turso`:

```swift
.package(
  url: "https://github.com/your-org/sqlite-orbit",
  from: "0.1.0",
  traits: ["Turso"]
)
```

The trait also vends `TursoPool`, which enables Turso's MVCC journal and runs reads and writes on
separate connection pools. Ordinary writes use `BEGIN CONCURRENT`, while an explicit exclusive
write waits for every pool access ahead of it and uses `BEGIN IMMEDIATE` for schema work:

```swift
let driver = try TursoPool(path: databasePath, writerCount: 4)
let database = OrbitDatabase(writer: driver)

try await database.write { transaction in
  try transaction.execute(Reminder.insert { reminder })
}

try await driver.exclusiveWrite { transaction in
  try transaction.execute("CREATE TABLE archived_reminders (...)")
}
```

Concurrent write conflicts are rolled back and surfaced as `SQLiteError`; a transaction body is
never replayed implicitly. `readBlocking`, `writeBlocking`, and `exclusiveWriteBlocking` use the
same connection pools and admission order as their asynchronous counterparts. `TursoPool`
currently implements transaction access only; transaction and value observation remain on the
ordinary queue and pool drivers.

For local development, build Turso's `turso_sqlite3` crate and put `libturso_sqlite3.a` on the
linker's search path. `Scripts/build-turso-artifactbundle.sh` turns a Turso checkout into the
SwiftPM static-library artifact bundle intended for release distribution. The checked-in system
module and the bundle both expose the module as `TursoSQLite3`, so publishing the bundle does not
change SQLiteOrbit's Swift source.

Turso's compatibility surface is still smaller than SQLite's. SQLiteOrbit handles that boundary
explicitly:

- Missing authorizer callbacks broaden observed reads and writes to the whole database, and every
  write invalidates the statement cache. This loses precision, not correctness.
- Read transactions use the numeric spelling of `PRAGMA query_only`, which both engines accept.
- Trusted-schema hardening, custom scalar and aggregate functions, collations, and ordinary
  multiprocess file access throw `SQLiteFeatureUnavailableError` before SQLiteOrbit calls an
  unimplemented entry point. Use `TursoPool` for an MVCC database confined to one process, or
  `OrbitDatabase(localPath:)` for the existing observable, single-writer WAL pool.
- Turso currently finishes an executing statement when its C API resets or finalizes it. A lazy
  cursor still returns early to its caller, but cleanup may scan the statement's remaining rows;
  there is no safe client-side substitute for native early finalization.

The unavailable operations are `nil` in `SQLiteLibrary.turso`, while its `fileSharing` value is
`.singleProcess`. As Turso fills in its compatibility API, each operation can be enabled directly
without engine-specific branches throughout the driver.

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
    library.statements.preparation.prepare(transaction.sqliteConnection, $0, -1, 0, &statement, nil)
  }
  defer { _ = library.statements.execution.finalize(statement) }
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
  try transaction.find(Reminder.all, key: 42)  // throws OrbitDatabaseRecordNotFoundError
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

When a column does not decode, the failure is an `OrbitDatabaseColumnDecodingError` naming the
column's index and name, the storage class actually found, and the statement's SQL.

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

## Encrypted databases

With the `SQLCipher` trait enabled, an encrypted database needs only a key:

```swift
let database = try OrbitDatabase(
  path: databasePath,
  configuration: .sqlCipher(key: .passphrase(secret))
)
```

A build with a codec adds `sqlite3_key_v2` and `sqlite3_rekey_v2`, which stock SQLite does not
have. `SQLiteConfiguration.sqlCipher(key:)` pairs the key with a library that has them, so there is
nothing to get wrong. Supplying your own build with a codec means filling the same two entry points
in yourself:

```swift
var library = myCipherBuild
library.encryption = SQLiteLibrary.Encryption(
  key: sqlite3_key_v2,
  rekey: sqlite3_rekey_v2
)

var configuration = SQLiteConfiguration(library: library)
configuration.key = .passphrase(secret)

let database = try OrbitDatabase(path: databasePath, configuration: configuration)
```

The key is applied before every other thing a connection does — before the first statement, and
before anything reads the file — so nothing can precede it and find the database unreadable. Every
connection a pool opens is keyed, not only its writer.

`SQLiteKey` is handed to the build as bytes rather than run as `PRAGMA key`, so the key is never
prepared, never cached, and never carried by the `sql` of the error a wrong key produces. It holds
its own copy of the material and wipes it when the last reference goes away, and it prints as
`SQLiteKey(redacted)` so that logging a configuration cannot spill it. That wiping limits how long
the key sits in freed memory rather than guaranteeing anything about the process, and it cannot
reach material you hold: the `String` a passphrase was read from stays yours to manage.

`withUnsafeBytes` lends the key out for work the package does not model — calling a build's
`sqlite3_rekey_v2` from a `SQLiteConnectionSetup`, or keying a database brought in with `ATTACH`:

```swift
configuration.connectionSetups.append(
  SQLiteConnectionSetup { connection in
    key.withUnsafeBytes { bytes in
      connection.sqlite.encryption!.rekey(
        connection.sqliteConnection,
        "main",
        bytes.baseAddress,
        Int32(bytes.count)
      )
    }
  }
)
```

Setting a key on a library with no `encryption` fails the open with
`SQLiteEncryptionUnavailableError` rather than opening an unencrypted database. Stock SQLite has no
codec, so that is a fact about the build rather than a claim about it.

A codec accepts any key and only reports a wrong one once something reads the file, so a keyed
connection reads the schema while it is being configured. A wrong key fails the open rather than
the first query the caller happens to run.

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

These helpers work against any SQLite build. A collation's comparator is handed its own user data
directly, and a function's callbacks read their arguments and write their results through the same
`SQLiteLibrary` the connection was opened with, so a caller-supplied build drives them exactly as
the linked one does.

`OrbitDatabase` is `Identifiable`. Its native writer supplies the default database
identifier, and callers can override it when constructing the database. File databases derive a
stable identifier from their absolute paths; a database private to its connection is not the same
database as any other, so each one receives a unique identifier.

## Database regions

`OrbitDatabaseRegion` describes a set of database columns without opening or inspecting a
database. A region can be empty, cover the full database, cover whole tables, or cover selected
columns:

```swift
let everything = OrbitDatabaseRegion.fullDatabase
let reminders = OrbitDatabaseRegion(Reminder.self)
let titles = Reminder.databaseRegion(\.title)
let visibleFields = Reminder.databaseRegion { ($0.title, $0.isCompleted) }
let rawColumns = OrbitDatabaseRegion(columns: ["title", "isCompleted"], in: "reminders")
let archived = OrbitDatabaseRegion(table: "reminders", schema: "archive")
```

Typed table instances produce the region of their entire table; their stored values do not narrow
the region. Raw regions default to `SQLiteSchemaName.main`; use `.temp` or a string literal for a
temporary or attached schema. Regions conform to `SetAlgebra`, supporting union, intersection,
symmetric difference, subtraction, containment, and overlap testing. Subtraction can express
exclusions such as every column in a table except one particular column. Whole-table regions absorb
their column regions, while regions for distinct tables or schemas do not intersect.

A read transaction can derive the region of a `QueryFragment` by asking SQLite to compile it:

```swift
let region = try await database.read { transaction in
  try OrbitDatabaseRegion(
    #sql("SELECT title FROM reminders WHERE NOT isCompleted", as: String.self).query,
    in: transaction
  )
}
```

Compilation resolves tables, columns, views, and attached schemas without executing the statement
or evaluating its bindings. Region derivation rejects statements that may write and treats
read-only pragmas as full-database reads. Query-backed value observations use this region to avoid
refetching after unrelated writes.

## Observation

`SQLiteQueue`, `SQLitePool`, and `OrbitDatabase` are observable databases. A value observation
fetches an initial value, then fetches again after a committed write that may affect its region.
`trackingAll` and `trackingOne` derive that region directly from a readable query:

```swift
let reminders = OrbitValueObservation.trackingAll(
  Reminder.where { !$0.isCompleted }
)

let firstReminder = OrbitValueObservation.trackingOne(
  Reminder.order { $0.id }
)

for try await reminders in reminders.values(in: database) {
  render(reminders)
}
```

For a custom fetch, the observation tracks every region read by the closure and updates its region
after each successful fetch. It also tracks properties read from Swift `Observable` values:

```swift
let incompleteCount = OrbitValueObservation.tracking { transaction in
  try transaction.fetchCount(Reminder.where { !$0.isCompleted })
}
```

`OrbitValueObservation.ExternalValue` is a thread-safe observable reference for simple external
state. Dynamic member lookup tracks only the fields the fetch actually reads:

```swift
struct Filters: Sendable {
  var showsCompleted = false
  var ordering = Ordering.date
}

let filters = OrbitValueObservation.ExternalValue(Filters())
let reminders = OrbitValueObservation.tracking { transaction in
  if filters.showsCompleted {
    try transaction.fetchAll(Reminder.where(\.isCompleted))
  } else {
    try transaction.fetchAll(Reminder.where { !$0.isCompleted })
  }
}

filters.ordering = .title       // Does not refetch this observation.
filters.showsCompleted = true   // Refetches with the other branch.
```

Access `.value` when the entire wrapped value is a dependency. Use `update` for an atomic
read-modify-write. Every successful fetch replaces its previous observable and database
dependencies, so conditionals follow only their currently active branch. Other `Observable` types
participate automatically when they can be safely read from the fetch's nonisolated executor;
actor-isolated models cannot be captured and read there directly.

Pass `region:` to use an explicit region instead. A fetch that uses `sqliteConnection` directly can
include those dependencies by calling `transaction.notifyReads(in:)`.

Commits from the observed driver, another database handle, or another process carry regions, so
observations avoid refetching after unrelated writes. A custom observable database that reports a
commit without a region is handled conservatively.

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
  case .observable:
    updateFromObservableState(change.value)
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
let scheduler = OrbitMainActorValueObservationScheduler.mainActor.animation(.default)
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

For transaction lifecycle events that do not produce a value, register an
`OrbitDatabaseTransactionObserver` directly with any `OrbitObservableDatabase`. Its
`databaseDidRead(in:)` hook receives regions read by local transactions.
`databaseDidChange(in:)` receives each provisional region from a directly observed write, or the
aggregate committed region from another handle. `databaseWillCommit` receives a read-only view of
a pending local transaction and may throw to abort the write, and `databaseDidCommit` identifies
the transaction's local or external origin. Work performed directly through `sqliteConnection`
can publish its regions explicitly:

```swift
try await database.write { transaction in
  try performDirectSQLiteRead(transaction.sqliteConnection)
  transaction.notifyReads(in: Reminder.databaseRegion)

  try performDirectSQLiteWrite(transaction.sqliteConnection)
  transaction.notifyChanges(in: Reminder.databaseRegion)
}
```

Read notifications are immediate and remain local to the process. Repeated calls publish repeated
observer events. A rollback follows provisional changes with `databaseDidRollback`.

## Fetch properties

`@FetchAll`, `@FetchOne`, and `@Fetch` are the property wrappers over that observation machinery.
A property declares the query it wants, and stays current with it:

```swift
@Table struct Reminder { let id: Int; var title: String; var isCompleted = false }

struct RemindersView: View {
  @FetchAll(Reminder.where { !$0.isCompleted }.order(by: \.title)) var reminders
  @FetchOne(Reminder.all.count()) var total = 0

  var body: some View {
    List(reminders, id: \.id) { reminder in Text(reminder.title) }
    Text("\(reminders.count) of \(total)")
  }
}
```

`@FetchAll` produces every row a query returns, and fetches an entire table when declared without
one. `@FetchOne` produces a single value: a count, an aggregate, or a row. A property whose value
is not optional keeps the value it was declared with until the first read finishes, and a query
that returns no row fails it with `OrbitDatabaseRecordNotFoundError`; declaring the value optional
makes an absent row `nil` instead.

```swift
@FetchAll var reminders: [Reminder]                       // Every reminder.
@FetchOne(Reminder.find(id)) var reminder: Reminder?      // One row, or nil.
@FetchOne(Reminder.all.count()) var count = 0             // An aggregate.
```

`@Fetch` takes an `OrbitFetchKeyRequest`, which is what several queries that must agree with one
another are written as. Its `fetch` runs in one read transaction, so the values it assembles come
from a single snapshot, and the property refetches when a write touches any region any of them
read:

```swift
struct RemindersOverview: OrbitFetchKeyRequest {
  struct Value: Sendable {
    var incompleteCount = 0
    var newest: [Reminder] = []
  }

  func fetch(_ transaction: borrowing SQLiteReadTransaction) throws -> Value {
    try Value(
      incompleteCount: transaction.fetchCount(Reminder.where { !$0.isCompleted }),
      newest: transaction.fetchAll(Reminder.order { $0.createdAt.desc() }.limit(10))
    )
  }
}

@Fetch(RemindersOverview()) var overview = RemindersOverview.Value()
```

### The database a property reads

A property is created wherever the property it wraps lives, which is rarely somewhere a database is
at hand, so it reads from `OrbitDefaultDatabase.current` unless it is given one:

```swift
@main
struct RemindersApp: App {
  init() { OrbitDefaultDatabase.set(try! appDatabase()) }
  var body: some Scene { WindowGroup { RemindersView() } }
}
```

`OrbitDefaultDatabase.withValue(_:operation:)` overrides it for the duration of an operation, which
is how a test gives itself a database of its own without touching the process-wide one. A property
built with no database at all, in a process that has no default, keeps the value it was declared
with and reports an `OrbitMissingDefaultDatabaseError` through `loadError` rather than trapping, so
a view built before its database exists still renders.

A property does not query until something reads it. Reading it the first time performs the fetch
and starts the observation, so a SwiftUI view can be re-created as often as SwiftUI likes without
each rebuilt property costing a query.

### The projected value

The projected value is the rest of the property: whether a read is in flight, the error one failed
with, a reader for one of its members, and the queries it can be given later.

```swift
@FetchAll(Reminder.all) var reminders

$reminders.isLoading           // Whether a read is in flight.
$reminders.loadError           // The error the last read failed with.
try await $reminders.load()    // Read the same query again.
let count = $reminders.count   // An `OrbitFetchReader<Int>`.

// Every value the property observes, starting with the rows as they stand.
for await reminders in $reminders.values {
  render(reminders)
}
```

A read that fails leaves the value the property last produced in place, reports the error through
`loadError`, and ends the observation; `load()` reads again and resumes it, which is what a retry
button calls.

`load(_:)` replaces the query the property observes, which is what a filter or a sort control
drives:

```swift
try await $reminders.load(Reminder.where { $0.title.contains(search) })
```

It returns an `OrbitFetchSubscription`. Awaiting its `task` ties the observation to the lifetime of
a SwiftUI view's `task`, so drilling into a child screen stops the query and popping back restarts
it:

```swift
.task { try? await $reminders.load(Reminder.order(by: \.title)).task }
```

Assigning one projected value to another hands over its query, and a reader projected from a member
stays current with the rest of the property.

### Where values are delivered

By default a property fetches its first value on the thread that first reads it, and delivers later
ones as the observation produces them. Pass a `scheduler:` to move that elsewhere — any
`OrbitValueObservationScheduler`, including `.mainActor` — or, in SwiftUI, an `animation:`, which
delivers every change on the main actor inside that animation:

```swift
@FetchAll(Reminder.all, animation: .default) var reminders
@FetchAll(Reminder.all, scheduler: .mainActor) var reminders
```

### Sections

`@FetchAll` can have the database group its rows. The `sectionBy:` expression is selected alongside
each row and ordered ahead of the query's own ordering, so one pass over the result set both
decodes the rows and lays out the sections:

```swift
@FetchAll(Reminder.order(by: \.title), sectionBy: \.priority) var reminders

var body: some View {
  List {
    ForEach($reminders.sections) { section in
      Section(section.name ?? "None") {
        ForEach(section, id: \.id) { reminder in Text(reminder.title) }
      }
    }
  }
}
```

The expression can be an ordering, or any expression of the query's tables:

```swift
@FetchAll(Reminder.all, sectionBy: { $0.priority.desc(nulls: .last) }) var reminders
@FetchAll(
  Reminder.join(RemindersList.all) { $0.listID.eq($1.id) }.select { ... },
  sectionBy: { _, list in list.title }
) var rows
```

`wrappedValue` is still the flat array of rows in the order the query produced them. A property
with no `sectionBy:` expression still projects `sections`: a single section, named `nil`, holding
every row.

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

let databaseIdentifier = OrbitDatabaseIdentifier(rawValue: "example.sqlite")
let subscription = try transport.subscribe(to: databaseIdentifier) { message in
  switch message {
  case .transactionDidCommit:
    refreshObservations()
  @unknown default:
    break
  }
}

try await transport.send(
  .transactionDidCommit(
    .init(databaseIdentifier: databaseIdentifier, region: .fullDatabase)
  )
)
```

Retain the `OrbitSubscription` for as long as messages should be delivered. Cancelling it, or
releasing its final copy, removes the process's registration when it has no other subscriber for
that database.

Delivery is bounded, at-most-once, and nondurable. Each send broadcasts to the peer processes that
are discoverable at that moment. A successful return means every discovered peer accepted the
message into its kernel receive queue, not that its handler has already run. No unbounded
user-space queue is used:

- `.fail` attempts every peer once and reports an `OrbitIPCPartialDeliveryError` if any queue is
  full or another peer fails.
- `.suspend(upTo:)` retries only backpressured peers until the shared deadline, then reports partial
  delivery. Task cancellation also cancels the wait.

Messages use a private versioned binary envelope and are decoded from `Span`; callers exchange
`OrbitIPCMessage` values rather than serialized `Data`. `OrbitIPCMessage` is nonexhaustive so
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
// Peers have now been sent .transactionDidCommit with the transaction's aggregate region.
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
