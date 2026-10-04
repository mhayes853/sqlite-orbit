# sqlite-orbit

> [!IMPORTANT]
> This is entirely agent written and is mainly a prototype.

`sqlite-orbit` is a SQLite application framework for Swift: typed transactions, lazy cursors,
value observation, and cross-process coordination, so several processes can share one database
and react to each other's writes.

```swift
import SQLiteOrbit

let database = try OrbitIPCDatabase(path: databasePath)

try await database.write { transaction in
  try transaction.execute("INSERT INTO reminders (title) VALUES (\(title))")
}

let titles = OrbitValueObservation.tracking { transaction in
  try transaction.fetchAll("SELECT title FROM reminders ORDER BY title") { row in
    row[0].textValue ?? ""
  }
}
for try await titles in titles.values(in: database) {
  render(titles)
}
```

`OrbitDatabaseReader` and `OrbitDatabaseWriter` define the synchronous and asynchronous boundaries
around the native SQLite implementation, which lends distinct `SQLiteReadTransaction` and
`SQLiteWriteTransaction` values. Read transactions can only query, while write transactions can
query and execute mutations. Transactions and rows are nonescapable, so a database-owned SQLite
connection cannot outlive its access closure. `OrbitValueObservation` builds callback and
asynchronous-sequence observation on that transaction boundary, both within one process and across
cooperating processes.

Queries are written as raw `SQL`, and
[swift-structured-queries](https://github.com/pointfreeco/swift-structured-queries) adds a type-safe
query builder on top of it behind the `StructuredQueries` trait, which is on by default.

## Raw SQL

`SQL` is a string literal whose interpolated values are bound as parameters rather than spliced into
the text, so a value can never change what a statement means. Interpolating other `SQL` splices it
in along with its own parameters, which is how a statement is composed from parts:

```swift
let title = "Get milk"
let isCompleted: SQL = "is_completed = \(false)"
try await database.write { transaction in
  try transaction.execute("INSERT INTO reminders (title) VALUES (\(title))")
  try transaction.execute("UPDATE reminders SET priority = \(2) WHERE \(isCompleted)")
}
```

Any `ConvertibleToOrbitDatabaseValue` binds as a parameter: the standard library's numbers, `Bool`,
`String`, `[UInt8]`, `OrbitDatabaseValue`, their optionals, and your own types. An enum whose raw
value converts conforms with no body, as in `enum Priority: Int, OrbitDatabaseValueConvertible`.
`\(quote:)` splices in a quoted identifier, and `\(raw:)` splices in text as it is, for the parts of
a statement that are chosen at runtime but cannot be bound. `+`, `append`, and `joined(separator:)`
build a statement from pieces. There is deliberately no initializer from a `String` value.

Rows are read by position or by column name, as `OrbitDatabaseValue`s, one of SQLite's five storage
classes:

```swift
let reminders = try await database.read { transaction in
  try transaction.fetchAll("SELECT id, title FROM reminders WHERE list_id = \(listID)") { row in
    (id: row[0].integerValue ?? 0, title: row[column: "title"]?.textValue ?? "")
  }
}

let count = try await database.read { transaction in
  try transaction.fetchOne("SELECT count(*) FROM reminders") { $0[0].integerValue }
}
```

A `ConvertibleFromOrbitDatabaseValue` reads strictly by storage class, so `NULL` only reads as an
optional, and a column that does not convert throws an `OrbitDatabaseColumnDecodingError`:

```swift
let priority = try row[column: "priority", as: Priority?.self]
let titles = try transaction.fetchAll("SELECT title FROM reminders", as: String.self)
```

For a type made from an entire row, use `ConvertibleFromOrbitDatabaseRow`. `@OrbitRow` synthesizes
its initializer for a struct, using property names as result-column names. `@OrbitColumn` overrides
a name:

```swift
@OrbitRow
struct ReminderSummary: Sendable {
  let id: Int
  let title: String
  @OrbitColumn("due_date") let dueDate: String?
}

let summaries = try await database.read { transaction in
  try transaction.fetchAll(
    "SELECT due_date, title, id FROM reminders ORDER BY id",
    asRow: ReminderSummary.self
  )
}

let titles = try await database.read { transaction in
  try transaction.fetchCursor(
    "SELECT id, title, due_date FROM reminders",
    asRow: ReminderSummary.self
  )
  .map(\.title)
  .collect()
}
```

`asRow:` passes the entire borrowed row to the initializer; `as:` reads its first column. Named
reads match UTF-8 bytes exactly, including case, and choose the first duplicate name. Missing
columns throw even for optional properties; SQL `NULL` can produce `nil`. The native cursor
prepares its column-name mapping on the first named read and shares it across subsequent rows.
Reordered and extra columns are supported. Initialized values own their data, while cursors must
be consumed inside their transaction. Write transactions support `asRow:` on `fetchAll`,
`fetchOne`, and `executeCursor` for `RETURNING` results.

The row protocol and macros are available without `StructuredQueries` or `Foundation`. Stored
instance properties must have explicit types conforming to `ConvertibleFromOrbitDatabaseValue`.
Computed and static properties are ignored, and memberwise initialization is preserved. Mutable
properties may have defaults, but missing columns still throw. For initialized `let` properties,
lazy properties, property wrappers or other property attributes, conditional members, or custom
initialization, write the conformance yourself:

```swift
struct ReminderSummary: ConvertibleFromOrbitDatabaseRow, Sendable {
  let id: Int
  let title: String

  init<Row: OrbitDatabaseRow & ~Copyable & ~Escapable>(
    orbitDatabaseRow row: borrowing Row
  ) throws {
    id = try row[column: "id", as: Int.self]
    title = try row[column: "title", as: String.self]
  }
}
```

`@OrbitRow` maps SQL result columns into values, including projections, joins, aggregates, and
`RETURNING` results. For typed inserts, updates, and upserts, use Structured Queries' `@Table`
models and write builders with `transaction.execute(Table.insert { ... })` or
`transaction.execute(Table.upsert { ... })`.

`rowCursor` lends the rows lazily. A write transaction also runs `execute`, `executeRowCursor`, and
its own `fetchAll` and `fetchOne`, which accept SQL that writes, so a `RETURNING` clause can be
read:

```swift
let deletedIDs = try await database.write { transaction in
  try transaction.fetchAll("DELETE FROM reminders WHERE is_completed RETURNING id") {
    $0[0].integerValue ?? 0
  }
}
```

`SQL` runs one statement. A script of several, such as a schema, runs with `executeScript`, which
takes a plain `String` and binds nothing:

```swift
try await database.write { transaction in
  try transaction.executeScript(
    """
    CREATE TABLE lists (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
    CREATE TABLE reminders (id INTEGER PRIMARY KEY, listID INTEGER REFERENCES lists (id));
    """
  )
}
```

An `OrbitDatabaseQuery<Access>` pairs SQL with the capability it requires, and a read transaction
only accepts `OrbitDatabaseQuery<OrbitDatabaseReadAccess>`. Raw SQL cannot show that it only reads
through its type, so a read query is checked with `sqlite3_stmt_readonly` when it is prepared, and
one that may write is refused with a `SQLiteError` whose code is `.readOnly` before it runs. That
includes pragmas that can change state as well as report it, such as `PRAGMA journal_mode`; read
those through their table-valued form, `SELECT * FROM pragma_journal_mode`, or in a write
transaction.

## Traits

| Trait | Default | Adds |
| --- | --- | --- |
| `SystemSQLite` | Yes | Links the platform SQLite and vends `SQLiteLibrary.system`. |
| `StructuredQueries` | Yes | The swift-structured-queries query builder, `@FetchAll`, `@FetchOne`, `@Row`, `@SingleRow`, and typed regions and observations. Re-exports `StructuredQueriesSQLite` and enables `Foundation`. |
| `Foundation` | Yes | `Date`, `UUID`, and `Data` conversions to and from `OrbitDatabaseValue`, so they bind in and read from raw SQL, with `OrbitUnixTimeDate` and `OrbitJulianDayDate` to store a date as a number instead of ISO 8601 text, using FoundationEssentials where the toolchain has it. |
| `SQLCipher` | No | Links SQLCipher in place of the system SQLite. |
| `Turso` | No | Links Turso's engine and vends `SQLiteLibrary.turso` and `TursoPool`. |
| `Dependencies` | No | Integrates `OrbitDefaultDatabase` with swift-dependencies. |
| `Vectors` | No | Re-exports SQLite Vec's C and query-core bindings, adds raw SQL conversions for `EmbeddingVector`, and initializes Vec automatically on supported connections. |

Every trait only adds API: SQL that compiles with a trait off compiles, and runs the same, with it
on. `Vectors` also initializes its extension when opening connections. Naming any trait in a
manifest leaves the defaults out, so a lean build lists only what it
needs:

```swift
.package(
  url: "https://github.com/your-org/sqlite-orbit",
  from: "0.1.0",
  traits: ["SystemSQLite"]
)
```

With the trait on, `import SQLiteOrbit` re-exports `StructuredQueriesSQLite`, so code that builds
statements needs no import of its own:

```swift
import SQLiteOrbit

@Table struct Reminder {
  let id: Int
  var title = ""
  var isCompleted = false
}

let pending = try await database.read { transaction in
  try transaction.fetchAll(Reminder.where { !$0.isCompleted })
}
```

A statement converts to raw SQL with `SQL(fragment: statement.query)`, and a query expression can
be interpolated into `SQL` directly. Whether a statement needs a write transaction is read off its
type: every `SELECT`-shaped statement can become a read query, and any statement at all can become a
write query, so a read transaction cannot be handed an `INSERT`, `UPDATE`, `DELETE`, or trigger
definition at compile time. Statements the query library keeps private, such as the one behind
`union`, are classified too.

## Reminders demo

The [Reminders example](Examples/Reminders/README.md) is an iOS app demonstrating migrations, observed
queries, aggregate counts, transactional forms, FTS5 search, and database-backed view settings.
Open `Examples/Reminders/Reminders.xcodeproj`, select the **Reminders** scheme, and run it on an iOS 17 or later
simulator. The first pass intentionally has no CloudKit synchronization or third-party dependency
management.

## Drivers

The package ships its own SQLite driver, which is the default and needs no third-party dependency:

```swift
import SQLiteOrbit

let database = try OrbitIPCDatabase(path: databasePath)

try await database.write { transaction in
  try transaction.execute("INSERT INTO reminders (title) VALUES (\(title))")
}

let titles = try await database.read { transaction in
  try transaction.fetchAll("SELECT title FROM reminders") { $0[0].textValue ?? "" }
}
```

Two ordinary SQLite drivers provide process-local access, and the multiprocess-capable pool backs
`OrbitIPCDatabase`:

- `SQLitePool` runs the database in WAL mode with one writer and a fixed set of readers.
  Reads run alongside one another; a write waits for the reads in flight and holds off the reads
  queued behind it, so a read issued after a write observes it. Waiting suspends rather than
  blocking a thread.
- `SQLiteQueue` serializes every access through a single connection. This is the driver for an
  `OrbitDatabasePath.memory` or `.temporary` database, which is private to the connection that
  opened it and so cannot be pooled at all.

Each connection runs on a serial executor of its own, a dispatch queue on Apple platforms and
Windows and a thread it starts on demand elsewhere, so a query never occupies a cooperative-pool thread.

### Suspending a shared database

An iOS app that is suspended while its SQLite connection holds a write lock on a database shared
with another process can be terminated with `0xDEAD10CC`. `SQLitePool` and the default
`OrbitIPCDatabase` support `suspend()` and `resume()`. Suspension interrupts the active writer and
refuses new write statements until the database resumes; a refused operation throws
`OrbitDatabaseSuspendedError`. Read connections remain available. `suspend()` starts the interruption
but does not wait for an in-flight write to finish rolling back, so database writes should still be
kept short and app lifecycle work should allow them to finish.

In a SwiftUI app on iOS, tvOS, or visionOS, put the modifier on a long-lived root view:

```swift
WindowGroup {
  RemindersRoot()
    .orbitDatabaseSuspension(database)
}
```

For UIKit, retain a controller for the database's lifetime. `.application` observes the whole app;
`.scene(scene)` is for a database exclusively owned by that scene:

```swift
let database = try OrbitIPCDatabase(path: databasePath)
let suspension = OrbitDatabaseSuspensionController(
  database: database,
  observing: .application
)
```

On watchOS the SwiftUI modifier follows `scenePhase`. On macOS it observes AppKit application
activation; an inactive app may have merely lost focus, so use the explicit `isActive:` overload if
that policy is too broad. AppKit apps can likewise use a controller observing `.application`, or
retain a manual controller and drive it from their chosen signal:

```swift
let suspension = OrbitDatabaseSuspensionController(database: database)
suspension.setActive(false)  // The owner is about to be suspended.
suspension.setActive(true)   // The owner is active again.
```

SwiftUI views with their own lifecycle signal can use
`.orbitDatabaseSuspension(database, isActive: isActive)` on any Apple platform. Keep one lifecycle
owner per database; the modifier replaces its controller when the database instance changes. Do not
use a scene scope for a database shared between active scenes.
Custom `OrbitMultiprocessDatabaseWriter` implementations must implement `OrbitSuspendable`
so an `OrbitIPCDatabase` can forward these calls to its writer.

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

A little work cannot happen inside a transaction: SQLite ignores `PRAGMA foreign_keys` in one, and
refuses to `VACUUM` in one at all. `readWithoutTransaction` and `writeWithoutTransaction` lend a
connection whose statements each commit on their own, and whose `transaction` groups the ones that
must commit together:

```swift
try await database.writeWithoutTransaction { connection in
  connection.isForeignKeysEnabled = false
  try connection.transaction { transaction in
    try transaction.execute(Reminder.delete())
  }
}
```

Setting `isForeignKeysEnabled` takes effect before the connection's next statement or
`transaction`, which is also where a failure to apply it is thrown. It and the `busyTimeout` are put
back to their configured values when the access ends, even when it throws. Any other pragma stays
changed on the connection, so restore it before returning. Outside `transaction`, statements that
begin or end a transaction or a savepoint are refused, so the connection always knows what has
committed. Observers see each statement as a commit of its own, and an `OrbitIPCDatabase` announces
what committed once the access ends, even when it throws.

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
let database = try OrbitIPCDatabase(path: databasePath, configuration: configuration)
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
  try connection.execute("PRAGMA trusted_schema = \(raw: enabled ? "1" : "0")")
}
```

`SQLiteConnectionAccess.execute` takes `SQL`, binding its values, and `executeScript` runs a script
of several statements.

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
the traits exclusive in practice. Name `StructuredQueries` as well to keep the query builder:

```swift
.package(
  url: "https://github.com/your-org/sqlite-orbit",
  from: "0.1.0",
  traits: ["SQLCipher", "StructuredQueries"]
)
```

The experimental `Turso` trait downloads Turso's local Rust engine for Apple platforms and Linux
x86-64, drives it
through its SQLite-compatible C API, and vends `SQLiteLibrary.turso`:

```swift
.package(
  url: "https://github.com/your-org/sqlite-orbit",
  from: "0.1.0",
  traits: ["Turso"]
)
```

The package links a release-hosted, indexed SwiftPM artifact bundle built from Turso
`v0.8.0-pre.11`. `Scripts/build-turso-artifactbundle.sh` reproduces a platform slice from an
upstream Turso checkout; the release workflow merges the slices and partitions them into the
host-family archives referenced by the index.

The trait also vends `TursoPool`, which enables Turso's MVCC journal and runs reads and writes on
separate connection pools. Explicit concurrent writes use `BEGIN CONCURRENT`, while `write` waits
for every pool access ahead of it and uses `BEGIN IMMEDIATE` as a barrier for schema work:

```swift
let driver = try TursoPool(path: databasePath, writerCount: 4)

try await driver.concurrentWrite { transaction in
  try transaction.execute(Reminder.insert { reminder })
}

try await driver.write { transaction in
  try transaction.execute("CREATE TABLE archived_reminders (...)")
}
```

Concurrent write conflicts are rolled back and surfaced as `SQLiteError`; a transaction body is
never replayed implicitly. `readBlocking`, `writeBlocking`, and `concurrentWriteBlocking` use the
same connection pools and admission order as their asynchronous counterparts. `TursoPool` also
supports access outside a transaction, plus transaction and value observation. Each successful
concurrent writer publishes its own committed region; conflicts and rollbacks publish nothing.

For local development, build Turso's `turso_sqlite3` crate and put `libturso_sqlite3.a` on the
linker's search path. `Scripts/build-turso-artifactbundle.sh` turns a Turso checkout into the
SwiftPM static-library artifact bundle intended for release distribution. The checked-in system
module and the bundle both expose the module as `TursoSQLite3`, so publishing the bundle does not
change SQLiteOrbit's Swift source. Turso writes outside a transaction are barriers because they
may contain immediate transactions or schema-oriented statements.

Turso's compatibility surface is still smaller than SQLite's. SQLiteOrbit handles that boundary
explicitly:

- Missing authorizer callbacks broaden observed reads and writes to the whole database, and every
  write invalidates the statement cache. This loses precision, not correctness.
- Read transactions use the numeric spelling of `PRAGMA query_only`, which both engines accept.
- Trusted-schema hardening, custom scalar and aggregate functions, collations, and ordinary
  multiprocess file access throw `SQLiteFeatureUnavailableError` before SQLiteOrbit calls an
  unimplemented entry point. Use `TursoPool` directly for an observable MVCC database confined to
  one process. It cannot back an `OrbitIPCDatabase` because it does not conform to
  `OrbitMultiprocessDatabaseWriter`.
- Turso currently finishes an executing statement when its C API resets or finalizes it. A lazy
  cursor still returns early to its caller, but cleanup may scan the statement's remaining rows;
  there is no safe client-side substitute for native early finalization.
- Turso enforces foreign keys statement by statement but has no `PRAGMA foreign_key_check`, so
  `foreignKeyViolations()` throws `SQLiteFeatureUnavailableError` rather than report no
  violations. A migration the migrator would check before it commits, which is every migration
  by default, fails the same way before it runs; register migrations with
  `foreignKeyChecks: .immediate`, or set `defersForeignKeyChecks` to `false` first.

The unavailable operations are `nil` in `SQLiteLibrary.turso`, while its `fileSharing` value is
`.singleProcess` and its `isForeignKeyCheckAvailable` is `false`. As Turso fills in its
compatibility API, each operation can be enabled directly without engine-specific branches
throughout the driver.

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

With the `StructuredQueries` trait, statements come in four shapes, and `fetchAll`, `fetchOne`, and
`fetchCursor` cover all of them: a
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

Raw `SQL` can also decode existing `@Table` and `@Selection` types through `asStructuredRow:`,
without an additional conformance or annotation:

```swift
@Selection
struct ReminderSummary: Sendable {
  let id: Int
  let title: String
}

let summaries = try await database.read { transaction in
  try transaction.fetchAll(
    "SELECT id, title FROM reminders ORDER BY id",
    asStructuredRow: ReminderSummary.self
  )
}

let titles = try await database.read { transaction in
  try transaction.fetchCursor(
    "SELECT id, title FROM reminders",
    asStructuredRow: ReminderSummary.self
  )
  .map(\.title)
  .collect()
}
```

This uses Structured Queries' positional decoding, including `@Column(as:)` representations and
grouped columns. SQL must return columns in the type's expected projection order and storage
representations; column names are used for diagnostics. The output is `Value.QueryOutput`, so a
table alias can decode to its underlying model. `fetchOne` returns `nil` for no rows. Write
transactions expose the same eager overloads and `executeCursor(_:asStructuredRow:cached:)` for
`RETURNING`. The separate labels let types supporting both conversion systems choose between
their row initializer and Structured Queries decoding without overload ambiguity.

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
let database = try OrbitIPCDatabase(
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

let database = try OrbitIPCDatabase(path: databasePath, configuration: configuration)
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

## SQLite Vec

Enable the opt-in `Vectors` trait to make vector functions and `vec0` tables available on
connections opened with a `SQLiteConfiguration`:

```swift
.package(
  url: "https://github.com/mhayes853/sqlite-orbit",
  from: "0.1.0",
  traits: ["default", "Vectors"]
)
```

No application startup registration or extra Swift Testing trait is required. Vec initializes
before user connection setups and setup SQL, on writers, pool readers, and reopened connections:

```swift
let database = try SQLiteQueue(path: databasePath)
try await database.write { transaction in
  try transaction.executeScript(
    "CREATE VIRTUAL TABLE embeddings USING vec0(embedding float[3])"
  )
  try transaction.execute("INSERT INTO embeddings VALUES (1, vec_f32('[1,2,3]'))")
}
let nearest = try await database.read { transaction in
  try transaction.fetchAll(
    """
    SELECT rowid, distance FROM embeddings
    WHERE embedding MATCH vec_f32('[1,2,3]') AND k = 5
    ORDER BY distance
    """
  ) { row in
    try (row[0, as: Int64.self], row[1, as: Double.self])
  }
}
```

Apple system SQLite uses per-connection initialization, identified by its library capability rather
than its name or version. Other supported runtimes register Vec automatically before opening the
connection. Automatic registration affects every future connection in that SQLite runtime, including
connections outside Orbit; already opened connections are unaffected.

Custom builds opt into their own automatic registration bindings:

```swift
let library = #sqliteLibrary(module: "MySQLite", apis: [.standard, .autoExtensions])
let configuration = SQLiteConfiguration(library: library)
let database = try SQLiteQueue(path: databasePath, configuration: configuration)
```

On non-Apple platforms, the runtime must provide the extension API table and virtual-table
registration Vec requires; builds omitting these fail initialization. On Apple platforms, the SDK
compiles Vec against the linked `sqlite3_*` symbols directly, so a custom build must be their sole
provider. Turso and libraries without extension support fail the open with
`SQLiteFeatureUnavailableError`.

If you replace `configuration.connectionSetups`, call `configuration.registerSQLiteVec()` to restore
Vec initialization. Its registration uses the configuration's library at connection opening time.

The general `SQLiteLibrary.registerAutoExtension` and `cancelAutoExtension` APIs are available
without the Vec trait. Cancellation affects future connections and leaves already initialized ones
working. Initializers and their code must remain loaded while SQLite can call them.

With this trait, `import SQLiteOrbit` brings `StructuredQueriesSQLiteVecCore` into scope. Builds
using `SystemSQLite` also re-export `CSQLiteVec`; custom builds use Orbit's opaque C bridge to avoid
conflicts between their SQLite headers and the platform headers imported by `CSQLiteVec`.
`EmbeddingVector` conforms to
`OrbitDatabaseValueConvertible`, so raw SQL can bind and fetch vectors directly:

```swift
let vector = EmbeddingVector<3> { Float($0) }
try await database.write {
  try $0.execute("INSERT INTO embeddings VALUES (2, \(vector))")
}
let stored = try await database.read {
  try $0.fetchOne("SELECT embedding FROM embeddings WHERE rowid = 2", as: EmbeddingVector<3>.self)
}
```

Vectors use little-endian 32-bit float blobs. Decoding rejects other storage classes and blobs
whose size does not match the vector dimension. `EmbeddingVector` follows upstream's availability
on Apple platforms: iOS, macOS, tvOS, and visionOS 26 or later, and watchOS 26 or later.

Orbit uses only the `CSQLiteVec` and `StructuredQueriesSQLiteVecCore` products, without building or
linking SQLiteData/GRDB. The dependency is temporarily pinned to main commit `f980c99`, which
exposes the core product. The query-core bindings bring a transitive Foundation dependency even
when the general `StructuredQueries` trait is disabled; that trait still controls Orbit's full
query-builder integration.

## Collations and functions

Functions written in Swift are registered on a `SQLiteConfiguration`, and receive and return
`OrbitDatabaseValue`s. An `argumentCount` of `nil` takes any number of arguments, and an error a
function throws fails the statement that called it:

```swift
var configuration = SQLiteConfiguration.default
configuration.registerFunction("reversed", argumentCount: 1, isDeterministic: true) {
  arguments in
  arguments[0].textValue.map { .text(String($0.reversed())) } ?? nil
}
```

An aggregate builds up an accumulator over the rows of each group:

```swift
struct LongestText: SQLiteAggregateAccumulator {
  var longest: String?

  mutating func step(_ arguments: borrowing SQLiteFunctionArguments) throws {
    guard let text = arguments[0].textValue else { return }
    if text.count > longest?.count ?? -1 { longest = text }
  }

  func finish() throws -> OrbitDatabaseValue {
    longest.map(OrbitDatabaseValue.text) ?? nil
  }
}

configuration.registerAggregateFunction("longest", argumentCount: 1) { LongestText() }
```

With the `StructuredQueries` trait, collating sequences and functions can also be declared with the
`@DatabaseCollation` and `@DatabaseFunction` macros, and registered the same way:

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

let database = try OrbitIPCDatabase(
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

`OrbitIPCDatabase` is `Identifiable`. Its multiprocess writer supplies the default database
identifier, and callers can override it when constructing the database. File databases derive a
stable identifier from their resolved filesystem paths. Symbolic links in the file and its existing
parent directories are resolved even before the database file is created, so IPC discovery and
open locks agree across those aliases. `OrbitDatabasePath` keeps its original standardized spelling;
explicit identifiers remain application-defined. Identity is path-based, so hard links with different
names still need an explicit shared identifier. A database private to its connection receives a
unique identifier. Process-local drivers use their own identifiers but cannot be passed to
`OrbitIPCDatabase`.

## Migrations

`OrbitDatabaseMigrator` brings a database's schema up to date, one registered migration at a time.
Register every migration the application has shipped, oldest first, and migrate when the database
opens:

```swift
var migrator = OrbitDatabaseMigrator()
migrator.registerMigration("Create reminders") { transaction in
  try transaction.execute(
    "CREATE TABLE reminders (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
  )
}
migrator.registerMigration("Add completion") { transaction in
  try transaction.execute(
    "ALTER TABLE reminders ADD COLUMN isCompleted INTEGER NOT NULL DEFAULT 0"
  )
}

let database = try OrbitIPCDatabase(path: databasePath)
try await migrator.migrate(database)
```

Each pending migration runs in a write transaction of its own, which also records its identifier,
so a run that stops part way — on an error, or because its task was cancelled — resumes where it
stopped, and a migration that throws is rolled back with the error rethrown as it was. Whether
anything is pending is read before the write lock is taken: launching with a database that is
already up to date locks nothing and announces nothing to other processes. A migration that has
shipped must never change afterwards; register a new one instead. `migrateBlocking` does the same
from synchronous code.

`upTo:` stops after a given migration, which is how a test checks one migration against the data
the migrations before it left behind:

```swift
try await migrator.migrate(database, upTo: "Create reminders")
try await database.write { transaction in
  try transaction.execute("INSERT INTO reminders (title) VALUES ('Old')")
}
try await migrator.migrate(database, upTo: "Add completion")
```

A target that is not registered, or one that a later migration has already gone past, throws
`OrbitDatabaseMigrationTargetError` before anything is written.

### Foreign keys

A migration runs with foreign keys off by default, and the whole database is checked for violations
just before the migration commits. That is what makes SQLite's procedure for the schema changes
`ALTER TABLE` cannot make safe to follow — create the new table, copy the rows across, drop the old
one, rename the new one — since dropping a table other tables refer to with foreign keys on would
delete, or cascade to, every row that refers to it. A migration that leaves violations is rolled
back with an `OrbitDatabaseForeignKeyViolationError` listing them, and the migrations before it
stay applied.

Register a migration with `foreignKeyChecks: .immediate` to keep foreign keys enforced statement by
statement instead. The check reads every table with a foreign key, which on a large database takes
time. Setting `defersForeignKeyChecks` to `false` skips it for the deferred migrations registered
after that, which still run with foreign keys off, trading the guarantee for that time; the ones
registered earlier keep their check. A connection without foreign keys on has nothing to defer or
check. A rebuild outside the migrator runs the same check itself: `foreignKeyViolations()` is
available on every transaction and connection, and returns each `OrbitDatabaseForeignKeyViolation`.
Turso cannot run the check, so there a migration that would be checked throws
`SQLiteFeatureUnavailableError` before it runs; `.immediate` migrations, which Turso enforces as
they go, and unchecked ones apply as usual.

### The table of applied migrations

Applied migrations are recorded in a table named `orbit_migrations`, created by the first migration
to run. It has the layout GRDB gives its own table, so a database GRDB's `DatabaseMigrator` has been
migrating can continue its history under the same identifiers. `.grdb` is a migrator that records
it in GRDB's own `grdb_migrations` table:

```swift
var migrator = OrbitDatabaseMigrator.grdb
```

The inspection methods read that table from any read or write transaction, or from a connection
lent outside one, and take it unlabeled as GRDB's do: `appliedIdentifiers(_:)`,
`appliedMigrations(_:)`, `completedMigrations(_:)`, `hasCompletedMigrations(_:)`, and
`hasBeenSuperseded(_:)`. A database no migrator has run on has applied nothing, and reading it
creates no table. `migrations` lists the registered identifiers, and GRDB's
`disablingDeferredForeignKeyChecks()` returns a copy with `defersForeignKeyChecks` off.

### Several processes

Processes that share a database may all migrate it as they launch. Each migration's transaction
checks again, under the write lock, whether another process applied it in the meantime, so every
migration runs once. It waits for the lock as long as the connection's busy timeout allows, and
fails with `SQLITE_BUSY` once that runs out. To wait longer, migrate on a connection whose timeout
you raise, which is put back when the access ends:

```swift
try await database.writeWithoutTransaction { connection in
  connection.busyTimeout = .limit(.seconds(30))
  try migrator.migrate(connection)
}
```

A migration applied by a newer build of the application is tolerated: an older build migrates the
ones it knows and leaves the rest alone. `hasBeenSuperseded(_:)` tells the older build that it is
running against a schema it does not fully know:

```swift
if try await database.read({ try migrator.hasBeenSuperseded($0) }) {
  showUpdateRequiredAlert()
}
```

The migrations a run commits are announced together once it ends, so observations in other
processes fetch again after the schema they read has changed.

### Erasing during development

While migrations are still being designed, editing one that has already run is quicker than
registering another. With `eraseDatabaseOnSchemaChange` on, a migrator that finds a migration it
applied removed or renamed, or the schema no longer what its migrations produce, erases the database
and runs every migration from the first. That destroys data, so keep it out of the application you
ship:

```swift
var migrator = OrbitDatabaseMigrator()
#if DEBUG
migrator.eraseDatabaseOnSchemaChange = true
#endif
```

The migrator finds a change by applying the migrations to a temporary database, opened with the
same configuration, and comparing its schema with the database's; `hasSchemaChanges(_:)` asks the
same question without erasing anything. A database whose migrations have not changed is still
neither locked nor announced. The erase drops everything in one transaction and resets
`user_version` to 0, and observers and other processes see it as a change to the whole database.
With the flag on, an applied migration the migrator does not register counts as removed, so every
process that opens the database must register the same migrations: an older build erases what a
newer one migrated.

## Database regions

`OrbitDatabaseRegion` describes a set of database columns without opening or inspecting a
database. A region can be empty, cover the full database, cover whole tables, or cover selected
columns:

```swift
let everything = OrbitDatabaseRegion.fullDatabase
let reminders = OrbitDatabaseRegion(table: "reminders")
let rawColumns = OrbitDatabaseRegion(columns: ["title", "isCompleted"], in: "reminders")
let archived = OrbitDatabaseRegion(table: "reminders", schema: "archive")
```

With the `StructuredQueries` trait, regions can also be named through a table's type:

```swift
let reminders = OrbitDatabaseRegion(Reminder.self)
let titles = Reminder.databaseRegion(\.title)
let visibleFields = Reminder.databaseRegion { ($0.title, $0.isCompleted) }
```

Typed table instances produce the region of their entire table; their stored values do not narrow
the region. Raw regions default to `SQLiteSchemaName.main`; use `.temp` or a string literal for a
temporary or attached schema. Regions conform to `SetAlgebra`, supporting union, intersection,
symmetric difference, subtraction, containment, and overlap testing. Subtraction can express
exclusions such as every column in a table except one particular column. Whole-table regions absorb
their column regions, while regions for distinct tables or schemas do not intersect.

A read transaction can derive the region of raw `SQL` by asking SQLite to compile it:

```swift
let region = try await database.read { transaction in
  try OrbitDatabaseRegion("SELECT title FROM reminders WHERE NOT isCompleted", in: transaction)
}
```

Compilation resolves tables, columns, views, and attached schemas without executing the statement
or evaluating its bindings. Region derivation rejects statements that may write and treats
read-only pragmas as full-database reads. Query-backed value observations use this region to avoid
refetching after unrelated writes.

## Observation

`SQLiteQueue`, `SQLitePool`, `TursoPool`, and `OrbitIPCDatabase` are observable databases. A value
observation fetches an initial value, then fetches again after a committed write that may affect
its region.
With the `StructuredQueries` trait, `trackingAll` and `trackingOne` derive that region directly
from a readable query:

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

An observation also registers the region it reads with the database it observes, so that an
`OrbitIPCDatabase` whose transport filters by region spares it, and its process, announcements of
unrelated commits altogether. When a fetch reads beyond what was registered while it ran, the
observation widens the registration and then fetches again, so a commit that lands in between is
never missed.

The default refetch controller starts immediately and retries when a newer invalidation supersedes
its read. Turso applications with expensive fetches can wait for only the writers that were active
alongside the triggering commit, then fetch their combined result:

```swift
let reminders = OrbitValueObservation
  .trackingAll(Reminder.all)
  .refetching(.coalesced)
```

An isolated commit is not delayed, and writers that begin later do not extend the captured wait.
Use `.once` to perform one fetch for the accumulated database invalidations and publish it even if
it became stale. An observable dependency invalidated during that fetch still schedules separate
work to restore its one-shot registration. Custom
`OrbitValueObservationRefetchController` implementations receive a scoped, noncopyable context whose
snapshot exposes active-writer state, affected and tracked regions, and accumulated refetch
reasons. They build on `waitForActiveWriters()` and `fetch(publishing:)`; a controller owns its
retry loop and must finish with either a published or cancelled result.

Use `updates(in:)` when every accepted fetch matters, including one whose output was suppressed by
`filter`, `compactMap`, or `removeDuplicates`:

```swift
for try await update in reminders.updates(in: database) {
  switch update {
  case .emitted(let change):
    render(change.value)
  case .noEmission(let source):
    logger.debug("No value emitted after \(source)")
  }
}
```

An update counts an accepted fetch, not a database notification: a transaction rejected by
`filterTransactions`, or a fetch superseded before its result was accepted, produces no update.
The `noEmission` case has no value because operators such as `compactMap` may produce no value of
the observation's output type at all.

Use `changes(in:)` when only emitted values and the reason for each fetch matter. An initial fetch
has an `.initial` source; a committed transaction reports whether it came from this process or
another one:

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

All three sequences start observing when iteration begins, and buffer every element a slow consumer
has not taken yet. Pass a `bufferingPolicy` to bound that buffer, which lets a slow loop skip ahead
to the current state of the database rather than working through every intermediate one:

```swift
for try await change in reminders.changes(in: database, bufferingPolicy: .bufferingNewest(1)) {
  await render(change)
}
```

The callback API is the primitive beneath the asynchronous sequences. Use `onChange` for emitted
values only:

```swift
let subscription = try reminders.subscribe(
  to: database,
  onError: report,
  onChange: { change in render(change.value) }
)
```

Use `onUpdate` to receive the same emitted and no-emission outcomes as `updates(in:)`:

```swift
let subscription = try reminders.subscribe(
  to: database,
  onError: report,
  onUpdate: process
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
aggregate committed region from another handle or a concurrent-write driver.
`databaseWillCommit` receives a read-only view of a pending serial transaction and may throw to
abort the write, and `databaseDidCommit` identifies the transaction's local or external origin.
An observer that only cares about part of the database can say so, and change its mind later:

```swift
let subscription = try database.subscribe(
  transactionObserver: CommitLogger(),
  region: Reminder.databaseRegion
)
try subscription.updateRegion(Reminder.databaseRegion.union(Tag.databaseRegion))
```

The region is a lower bound: commits that overlap it are always reported, while commits outside it
made through other handles or by other processes may be skipped. Work performed directly through
`sqliteConnection` can publish its regions explicitly:

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
`@Fetch` is always available; `@FetchAll` and `@FetchOne` need the `StructuredQueries` trait.
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

`@Fetch` takes either an `OrbitFetchKeyRequest` or an `OrbitValueObservation`. A request is how
several queries that must agree with one another are written. Its `fetch` runs in one read
transaction, so the values it assembles come from a single snapshot, and the property refetches
when a write touches any region any of them read:

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

Passing a value observation directly preserves its operators, external dependencies, refetch
controller, and shared runtime:

```swift
let incompleteTitles = OrbitValueObservation
  .trackingAll(Reminder.where { !$0.isCompleted }.order(by: \.title))
  .map { $0.map(\.title) }
  .removeDuplicates()

@Fetch(incompleteTitles) var titles = [String]()
```

If `filter` or `compactMap` suppresses the initial value, the property keeps its declared value and
finishes loading normally while it waits for a later value the observation accepts.

Copies of one observation share an identity, so a stored observation survives SwiftUI view
reconstruction. When a declaration constructs a fresh observation each time, give it a stable
identity. Changing that identity replaces the observation:

```swift
@Fetch(makeObservation(for: filter), id: filter) var reminders = [Reminder]()
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
is how a test gives itself a database of its own without touching the process-wide one. Accessing
`OrbitDefaultDatabase.current`, or reading a property that cannot find a database, terminates with
detailed setup instructions. A SwiftUI property waits until its environment has been resolved, so
providing a database with `.orbitDatabase(...)` does not require a process-wide default.

Enable the `Dependencies` trait to configure the same default with
[swift-dependencies](https://github.com/pointfreeco/swift-dependencies):

```swift
.package(
  url: "https://github.com/your-org/sqlite-orbit",
  from: "0.1.0",
  traits: ["default", "Dependencies"]
)
```

```swift
import Dependencies
import SQLiteOrbit

prepareDependencies {
  $0.orbitDefaultDatabase = try! appDatabase()
}
```

`OrbitDefaultDatabase.current` and `@Dependency(\.orbitDefaultDatabase)` then resolve the same
database. An `OrbitDefaultDatabase.withValue` scope wins over a dependency override, and a
dependency override wins over the process default installed by `OrbitDefaultDatabase.set`.

The `SQLiteOrbitTestSupport` product supplies a Swift Testing trait that installs a task-local
database for every test case. A database construction expression is evaluated separately for each
case, so tests remain isolated while running in parallel:

```swift
import SQLiteOrbitTestSupport
import Testing

@Suite(.orbitDatabase(try testDatabase()))
struct RemindersTests {
  @Test func loadsReminders() {
    let model = RemindersModel()
    #expect(model.reminders.count == 2)
  }
}
```

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

`load(_:)` replaces the query or value observation the property observes, which is what a filter or
a sort control drives:

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
`OrbitValueObservationScheduler` that is also `Hashable`, including `.mainActor` — or, in SwiftUI,
an `animation:`, which delivers every change on the main actor inside that animation:

```swift
@FetchAll(Reminder.all, animation: .default) var reminders
@FetchAll(Reminder.all, scheduler: .mainActor) var reminders
```

Request-backed fetch identity follows SQLiteData: it includes the database instance, request type
and value, and optional scheduler value. An observation-backed fetch uses the observation's
definition identity, or the explicit `id:` supplied with it. Omitting a scheduler is distinct from
explicitly supplying `.immediate`. SwiftUI remembers the declaration's identity separately from
the currently loaded source, so a `load()` or projected-value assignment survives an unchanged
declaration being rendered again. Changing the declaration's request, observation identity,
database, or scheduler replaces the observation; a value-only declaration leaves it alone.

Custom schedulers should base equality and hashing on stable configuration (or instance identity),
not mutable callback queues. The built-in schedulers already provide these conformances. Direct
value-observation subscriptions do not require a `Hashable` scheduler. Fetch `animation:` overloads
require iOS 17, macOS 14, tvOS 17, or watchOS 10, matching `Animation`'s `Hashable` availability.

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
  configuration: .init(directory: coordinationDirectory)
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

Retain the `OrbitRegionSubscription` for as long as messages should be delivered. Cancelling it, or
releasing its final copy, removes the process's registration when it has no other subscriber for
that database.

Pass a `region:` to `subscribe` to hear only about commits that overlap it. Each process advertises
the union of its subscriptions' regions for a database in the coordination directory, and a sender
skips a process that union does not overlap, so an unrelated commit never wakes it. Widening a
region with `updateRegion(_:)` is advertised before the call returns.

Delivery is bounded, at-most-once, and nondurable. Each send broadcasts to the peer processes that
are discoverable at that moment, and never waits for one of them. A successful return means every
discovered peer either accepted the message into its kernel receive queue or is owed it, not that
its handler has already run.

A peer whose receive queue is full, such as a suspended app, is owed the message's region instead.
The regions of every commit it could not take are merged into one region per database, and a later
commit to a peer that is owed anything joins what it is owed rather than overtaking it. Once the
peer has room, the transport sends it one commit per database it is owed. A peer that falls behind
hears about fewer, broader commits, but never misses a change, and no unbounded user-space queue is
kept for it: what it is owed goes once it is sent, once the peer turns out to be dead, or once the
peer stops subscribing to that database. `UnixDatagramIPCTransport.PartialDeliveryError` reports
only peers the message could not be sent to at all.

Messages use a private versioned binary envelope and are decoded from `Span`; callers exchange
`OrbitIPCMessage` values rather than serialized `Data`. `OrbitIPCMessage` is nonexhaustive so
the library can add coordination messages in future versions.

## Opening a database for several processes

`OrbitIPCDatabase(path:)` owns opening the database, which is what lets it coordinate:

```swift
let database = try OrbitIPCDatabase(path: databasePath)
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
let database = try OrbitIPCDatabase(
  path: databasePath,
  coordination: .init(directory: appGroupDirectory)
)
```

A database private to its connection cannot be shared between processes, or pooled, so
`SQLitePool` rejects one; use `SQLiteQueue` for those.

Constructing an `OrbitMultiprocessDatabaseWriter` yourself remains available for a database you
configure and open on your own. That cannot coordinate opening, so pass a transport explicitly if
the database is also opened elsewhere. Process-local writers such as `SQLiteQueue` and `TursoPool`
do not satisfy that initializer.

## Announcing committed writes

A database announces every write transaction it commits:

```swift
try await database.write { transaction in
  try transaction.execute(Reminder.insert { reminder })
}
// Peers have now been sent .transactionDidCommit with the transaction's aggregate region.
```

The announcement is sent after the driver releases its write transaction, never inside it: a peer
told about a commit must be able to read it.

By the time a write commits it is already durable, so a failed announcement never fails the write.
Set an `OrbitIPCDatabase.Delegate` to observe an announcement immediately before its transport
attempt and after it either succeeds or fails. Success means every currently discoverable peer
accepted the message into its transport receive queue or will be sent it once it has room, not that
its handlers processed the message. On failure, the delegate receives the message that could not
reach every peer and the transport's error; the database does not retry because a failed send may
already have reached some peers. Announcing is likewise shielded from the writing task's
cancellation, since peers still need to learn about a commit that happened. A write that throws is
rolled back by its driver and is not announced.

An observed `OrbitIPCDatabase` also subscribes to its peers. Incoming announcements are exposed
as external transaction events and cause active value observations to refetch.
