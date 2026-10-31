# GRDB compatibility

`SQLiteOrbitGRDB` is an experimental, independently implemented compatibility product. It provides
common GRDB 7 application APIs over Orbit's connections, transactions, migrations, and observation.
GRDB itself is not a runtime dependency. The overlay is implemented entirely through SQLiteOrbit's public API; it imports no SPI. The verification baseline is GRDB 7.11.1.

Select the `SQLiteOrbitGRDB` product in your application's target dependencies and replace
`import GRDB` with `import SQLiteOrbitGRDB`. The normal `SQLiteOrbit` API remains available as a
separate product. The overlay requires SDKs that provide Foundation and Dispatch, including when Orbit's Foundation
trait is disabled. Core-only SDKs can continue to build SQLiteOrbit; compatibility declarations are
available when both modules are present. The StructuredQueries trait is not required. The overlay uses Orbit's existing Swift 6.2 and
platform minimums (including iOS 16 and macOS 13).

```swift
import SQLiteOrbitGRDB

struct Player: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
  var id: Int64?
  var name: String
  var score: Int

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

var migrator = DatabaseMigrator()
migrator.registerMigration("createPlayers") { db in
  try db.create(table: "player") { t in
    t.autoIncrementedPrimaryKey("id")
    t.column("name", .text).notNull()
    t.column("score", .integer).notNull().defaults(to: 0)
  }
}

let database = try SQLiteQueue(path: .memory)
try await migrator.migrate(database)
try await database.write { db in
  var player = Player(name: "Arthur", score: 100)
  try player.insert(db)
}

let observation = ValueObservation.tracking { db in
  try Player.order(Column("score").desc).fetchAll(db)
}
for try await players in observation.values(in: database) {
  // Render players.
}
```

## Drivers and access

`SQLiteQueue`, `SQLitePool`, `TursoPool` when its trait is enabled, and `OrbitIPCDatabase` conform
directly to the overlay's `DatabaseWriter` and `DatabaseReader`. These conformances belong to the
overlay target. `DatabaseQueue` and `DatabasePool` provide GRDB-style path/configuration initializers,
and `AnyDatabaseReader`/`AnyDatabaseWriter` erase the concrete driver type. All of these types accept
synchronous and asynchronous access, fetching, migration, and observation.

Native and compatibility overloads coexist. GRDB-style fetching or `db.execute(sql:)` selects the
compatibility overload; native transaction methods select native access. A closure that does not
identify either API may select native access. To force compatibility access, annotate the closure
parameter as `Database` or pass the driver through `any DatabaseWriter`.

`OrbitIPCDatabase` additionally observes writes announced by cooperating processes. Writes through
the overlay route through the IPC handle itself, preserving commit announcements. Synchronous IPC
writes retain Orbit's asynchronous announcement behavior; asynchronous writes await the announcement
attempt. Direct use of a pool or queue provides local observation.

The overlay exposes `path` and `configuration` for all built-in drivers. An IPC handle constructed
with a custom writer can perform access and observation, but metadata access requires that custom
writer to provide an `OrbitDatabaseReader.databaseMetadata` snapshot. Custom readers default to
`nil`. No database access is performed to retrieve metadata.
Native drivers also expose their native `configuration`. Use `any DatabaseReader` or an
`AnyDatabaseReader` wrapper when requesting GRDB-shaped configuration properties.

`write` runs the overlay's own transaction on the writer connection (`writeWithoutTransaction` plus
`inTransaction`), as GRDB does, so its BEGIN/COMMIT statements are traced and
`afterNextTransaction` callbacks run. Only transactions started through the overlay are visible
this way: the native core refuses raw `BEGIN`/`COMMIT` SQL outside its managed transactions.

`interrupt()` reaches every connection a queue or pool has opened. `close()` makes later accesses
fail with `SQLITE_MISUSE` and releases the native driver. `unsafeReentrantRead`/`Write` reuse the
current access on the same thread. `DatabasePool.makeSnapshot()` opens a dedicated read connection
outside the pool and keeps its read transaction open on a thread the snapshot owns, so the pool keeps
writing under WAL while the snapshot sees the state at its creation.

`asyncWrite(_:completion:)` commits or rolls back before calling completion, while still holding
the writer connection. Completion may access that connection, and the result need not be Sendable.
`asyncWriteWithoutTransaction(_:)` leaves transaction and SQL error handling to its closure.

`asyncUnsafeRead(_:)` provides read-only access without an implicit transaction. Consecutive
queries can see different commits from other connections. This retains Orbit's stricter read-only
rule: GRDB's unsafe queue reads can allow writes. The connection remains scoped to the callback.
`asyncMigrate(_:completion:)` runs pending migrations with the native migrator and calls success
on the same writer connection before releasing its barrier. Each migration has its own transaction;
on failure, earlier committed migrations remain applied. Acquisition and migration errors are
delivered as failures. Its completion may perform further writes.

These callback APIs schedule native async access in Swift tasks and retain the native driver's
access coordination, but do not guarantee GRDB's submission ordering relative to accesses issued
immediately after scheduling a callback. Chain dependent work from completion. Their database arguments are
scoped to the callbacks, and IPC announcements can follow completion when the access is released.
The `asyncWriteWithoutTransaction` callback signature cannot report failure to acquire a connection;
such a failure is a precondition failure (including when used by `asyncWrite`). SQL errors inside
`asyncWrite` are delivered to completion normally. Result-based read and migration callbacks deliver
at most one result, even if native access cleanup fails after the callback has run.

## Covered surface

| Area | Implemented APIs |
| --- | --- |
| Access | Sync/async `read`, `write`, `unsafeRead`, `writeWithoutTransaction`, reentrant reads/writes, barrier writes; callback `asyncRead`, `asyncUnsafeRead`, `asyncWrite`, `asyncWriteWithoutTransaction`, `asyncBarrierWriteWithoutTransaction`; queue `inDatabase`/`inTransaction`; explicit transactions and GRDB-style savepoints; `interrupt`, `close`, memory release; pool snapshots. |
| Configuration | Foreign keys, busy mode/callback, read-only databases, WAL journal mode, maximum reader count, `prepareDatabase`, `publicStatementArguments`, `transactionClock`, `schemaSource`, labels and the stored GRDB options, selection of a native SQLiteLibrary. |
| SQL and statements | Multi-statement execution, `allStatements`, literals and interpolation (identifiers, `columnsOf:`, `tableOf:`, subqueries), SQL composition, positional/named/numbered arguments, checked/unchecked arguments, prepared/cached statements, statement metadata, tracing with GRDB's expanded SQL, GRDB's error descriptions and result codes. |
| Values and rows | DatabaseValue, scalar and Foundation conversions (including NSNumber, NSString, NSData, NSDate, NSNull, NSURL, NSUUID, Decimal, NSDecimalNumber, CGFloat, DatabaseDateComponents, every GRDB date format), Codable values, owned rows, column-keyed access, prefetched rows, row adapters and scopes, GRDB's concrete cursor types and cursor algebra. |
| Records | FetchableRecord, EncodableRecord, TableRecord, PersistableRecord, MutablePersistableRecord, the `Record` base class with change tracking, persistence callbacks, conflict policies, UPSERT, RETURNING forms, record-not-found errors, Codable strategies, nested and prefetched Decodable records. |
| Query interface | GRDB's request protocols, expressions, operators, functions (aggregates with filters, date modifiers, casts, string transforms), selections (`allColumns`, `rowID`, exclusions), subqueries, table aliases, the typed `$0.column` closure DSL, ordering, grouping, bulk updates/deletes with RETURNING, common table expressions, and SQL text that matches GRDB's. |
| Associations | `belongsTo`, `hasOne`, `hasMany`, `hasOneThrough`, `hasManyThrough`, joins, `joining`/`including` (required, optional, and prefetched `all`), annotations and association aggregates, foreign keys, inflections, row scopes. |
| Schema | Table/column/index/view creation in GRDB's clause order, generated columns, foreign keys and `belongsTo` columns, alterations, virtual tables, schema introspection (columns, primary keys, indexes, foreign keys, schema IDs), schema sources for views, foreign-key checks. |
| Full-text search | FTS3, FTS4, and FTS5 table builders, synchronized tables, patterns, tokenizer descriptors, `matching`/`match`, FTS5 query tokenization through `fts5vocab`. |
| JSON | `JSONColumn`, `SQLJSONExpressible`, `->`/`->>`, and the `Database.json*`/`jsonb*` functions. |
| Migrations | Registration (including foreign-key-check modes and merged migrations), sync/async/callback migration, targets, history, schema-change detection, development reset. History uses `grdb_migrations`. |
| Observation | ValueObservation tracking (dynamic and explicit regions), schedulers (`.immediate`, `.mainActor`, `.task`, dispatch queues), `values(in:scheduling:bufferingPolicy:)`, `SharedValueObservation`, `print`, event hooks, `DatabaseRegionObservation`, row-id regions, conditional Combine publishers. |
| Connection setup | Custom functions, aggregates, collations, their IDs and removal, GRDB's default Unicode functions and collations. |
| Maintenance and diagnostics | WAL checkpoints, `dumpSQL`/`dumpRequest`/`dumpTables`/`dumpContent`/`dumpSchema` in all five formats. |

Rows fetched by `fetchAll` and `fetchOne` own their values. A row cursor reuses its current `Row`;
call `copy()` before retaining a row across cursor advances. Connections, cursors, and statements
must be used within their access closure. The overlay checks connection lifetime and thread
confinement and closes outstanding statements before returning a borrowed connection. Read-only
queries in synchronous accesses step raw statements through the selected library's function table
(validated, region-reported, and finalized before the access returns), which avoids copying every
row into owned values.

Observation uses native authorizer/cache metadata. Native writes and overlay writes affect the same
tracked regions. Explicit constant regions resolve inside the first observation read, avoiding a
blocking read when an async sequence is constructed. An observation can coalesce intermediate
changes; use `removeDuplicates` when equal fetched values should be suppressed.
Subscriptions and async iterators of the same observation definition on the same database share
native fetches, reducer state, cached values, and lifecycle callbacks. A late subscriber receives the
latest value. Scheduling and cancellation belong to each subscriber; iterators have separate
buffers. The runtime stops when its last subscriber leaves. Different databases or separately
constructed definitions use separate runtimes. This intentionally differs from GRDB's default
per-subscription lifecycle: `willStart` runs once per runtime and `didCancel` runs when the last
subscriber leaves. Row-id regions exist at the overlay level for descriptions and region algebra;
native observation tracks whole tables.

`Database.trace` reports the statements executed through the compatibility `Database`, including
the transaction statements of overlay-managed transactions, with SQLite's expanded-SQL spelling.
Statements executed through SQLiteOrbit's native APIs or by triggers are not reported.

UPSERT uses SQLite's atomic `ON CONFLICT DO UPDATE` and reports the rowid of the inserted or
updated row to insertion callbacks. It supports conflict targets, explicit assignments with the
`excluded` alias, and the `.noColumnUnlessSpecified` update strategy. Tables without rowids are
supported. Returning persistence APIs execute SQL `RETURNING`, so defaults and generated columns
are available and returned values precede changes made by AFTER triggers, as in SQLite and GRDB.
These APIs require a selected engine with the corresponding UPSERT/RETURNING support.

Bulk mutations bypass per-record persistence callbacks and use the record type's update conflict
policy unless explicitly overridden. Native observation and IPC announcements still apply.
SQLite performs all matching mutations on the first step of a RETURNING statement; consuming
one returned row does not limit how many rows are changed. Exhaust or release cursors before
leaving their database access. Decoding errors do not undo statement changes by themselves;
letting the error escape a transactional `write` rolls back the transaction.

Row adapters reshape fetched rows without changing the executed SQL, and `including(all:)` runs
GRDB's prefetch queries after the main fetch (`fetchCursor` refuses prefetching, as in GRDB):

```swift
struct Team: Codable, FetchableRecord, PersistableRecord, Sendable {
  static let players = hasMany(Player.self)  // `player` rows with a `teamId` column
  var id: Int64
  var name: String
}

struct TeamInfo: Decodable, FetchableRecord, Sendable {
  var team: Team
  var players: [Player]
}

let infos = try database.read { db in
  try Team.including(all: Team.players).asRequest(of: TeamInfo.self).fetchAll(db)
}
```

## Measured coverage

Coverage is measured against GRDB 7.11.1 in two ways, both reproducible with
`Tests/GRDBReference/grdb_upstream.py` (run with `python3 -I`; it uses the GRDB checkout that
`swift package resolve --package-path Tests/GRDBReference` fetches).

**Public API, by name.** `grdb_upstream.py api` extracts both modules' public symbol graphs and
matches declarations by path and kind (for example `DatabaseQueue.unsafeRead(_:)`, a method),
ignoring signatures. Inherited protocol members count for the overlay; deprecated, unavailable, and
underscored GRDB declarations are excluded.

| Area | Matched | GRDB declarations |
| --- | ---: | ---: |
| Core | 919 | 1055 |
| QueryInterface | 513 | 514 |
| Record | 200 | 202 |
| FTS | 86 | 114 |
| ValueObservation | 59 | 64 |
| Dump | 55 | 55 |
| JSON | 31 | 32 |
| Migration | 16 | 19 |
| Utils and other | 15 | 18 |
| **Total** | **1894 (91.4%)** | **2073** |

Before this work the overlay matched 1049 (50.6%).

**GRDB's own test suite.** Every upstream test file is ported verbatim into the Swift 5 target
`Tests/SQLiteOrbitGRDBUpstreamTests`; only the import line changes. The manifests in
`Tests/GRDBReference/upstream-manifest/` record, per file, the tests removed because they do not
compile against the overlay (`-`), the tests skipped at runtime with the failure reason (`~`), the
tests GRDB itself fails with this SQLite build (`!`), and files not ported (`x`). The same generated
files run against GRDB itself with GRDB's original harness and no skips.

| Area | Upstream tests | Compiled on Linux | Skipped | Running |
| --- | ---: | ---: | ---: | ---: |
| Core | 932 | 722 | 65 | 657 |
| Record | 732 | 713 | 0 | 713 |
| QueryInterface | 610 | 597 | 5 | 592 |
| FTS | 120 | 100 | 1 | 99 |
| ValueObservation | 119 | 79 | 55 | 24 |
| Support | 99 | 99 | 0 | 99 |
| Private | 89 | 23 | 4 | 19 |
| Dump | 55 | 55 | 0 | 55 |
| JSON | 54 | 54 | 0 | 54 |
| Migrations | 35 | 35 | 4 | 31 |
| Combine (Apple only, not ported) | 32 | 0 | 0 | 0 |
| **Total** | **2877** | **2477** | **134** | **2343** |

Of the 2343 running tests, 2297 pass and 46 are skipped by upstream itself on Linux. GRDB passes all
2477 compiled tests. 200 of the 227 upstream files are ported. "Compiled on Linux" excludes tests
that do not compile against the overlay and tests that upstream compiles only on Apple platforms or
with snapshot support. The port compiles upstream's Apple-only sections (`canImport(Combine)`,
`canImport(Darwin)`, `canImport(CoreGraphics)`) as absent on every platform, since they cannot be
verified on Linux. Type-checking every upstream file verbatim, 173 files and 2527 of 2877 tests
(87.8%) compile; before this work, 25 files and about 630 tests did.

```sh
python3 -I Tests/GRDBReference/grdb_upstream.py api        # name-level API coverage
python3 -I Tests/GRDBReference/grdb_upstream.py typecheck  # verbatim upstream files
python3 -I Tests/GRDBReference/grdb_upstream.py report     # per-area port status
python3 -I Tests/GRDBReference/grdb_upstream.py run --verify
```

After changing the overlay, `autoexclude all` recomputes which tests compile, `sync` regenerates the
target, and `run --record` (which ignores skips) makes the recorded skips exactly the failures.

## Compatibility boundaries

The remaining gaps fall into a few groups. Most need a capability the core does not expose; the
overlay never works around the core's guards.

| Gap | Upstream impact | Cause |
| --- | --- | --- |
| `TransactionObserver`, `DatabaseEvent`, `add(transactionObserver:)` | ~90 tests, 34 declarations | The core reports region-level commits only. Per-row events need SQLite's update, commit, and rollback hooks. `DatabaseRegionObservation` covers region-level use. |
| Pool reads overlapping writes, `spawnConcurrentRead`, `asyncConcurrentRead` | 16 skips, 3 declarations | Orbit's pool writes are barriers against the pool's reads. |
| Raw `BEGIN`/`COMMIT`, `beginTransaction`, `commit`, `rollback` | ~15 tests | The core refuses transaction SQL outside its managed transactions. Use `inTransaction`, `write`, or savepoints. |
| ValueObservation value-per-commit expectations | ~45 skips | Orbit's shared observation runtime coalesces commits made while a fetch is pending, and asynchronous schedulers may perform the initial fetch after a write issued right after `start`. |
| `StatementColumnConvertible`, `init(sqliteStatement:index:)`, `bind(to:at:)`, `Statement.sqliteStatement` | ~70 declarations, 2 files | Native cursors do not lend their raw statements. |
| FTS5 custom and wrapper tokenizers, `makeTokenizer` | ~40 declarations, 3 files | Requires the `fts5_api` pointer, obtained with `sqlite3_bind_pointer`, which the core's library table lacks. |
| Backup, `inMemoryCopy`, `temporaryCopy` | ~10 declarations, 4 files | The core's library table has no backup API. |
| `vacuum`, `vacuum(into:)` | 4 tests | VACUUM's internal transaction control is refused (`SQLITE_AUTH`) outside a managed transaction. |
| `Database.logError`, `lastErrorCode`, `suspendNotification` | a few declarations | Global SQLite logging and GRDB's suspension notifications have no core counterpart. |
| GRDB internals | ~60 tests in `Private/`, a few elsewhere | Tests of GRDB's private types (`OrderedDictionary`, `Pool`, schema cache, `SQLGenerationContext`). Not applicable. |

Other differences:

- `DatabaseQueue(named:)` gives a private in-memory database; named shared in-memory databases need
  URI opening.
- `Configuration.acceptsDoubleQuotedStringLiterals`, `qos`, `targetQueue`, and similar options are
  stored but not enforced (`sqlite3_db_config` is not in the library table), and
  `maximumStatementArgumentCount` is chosen by SQLite version rather than `sqlite3_limit`.
- `onConnectionDidOpen`/`onConnectionDidClose` are not provided: the overlay cannot observe a native
  connection closing.
- `DatabaseQueue.inDatabase` and queue/pool `unsafeRead` use typed throws, matching GRDB's
  `rethrows`; with a non-throwing closure, an access failure (such as a closed database) is fatal.
- `remove(function:)` and `remove(collation:)` replace the registration with one that fails or
  compares binary, since the core cannot unregister.
- Region descriptions lowercase identifiers and do not filter views.
- Pool readers are opened eagerly; `maximumReaderCount` maps to Orbit's fixed reader count.
- The selected engine must implement the operations used. Turso lacks custom functions, deferred
  foreign-key checks, FTS, and the C API used by a few upstream tests, which compile only without
  the Turso trait.
- Dependencies that expose types from the original GRDB module require source changes; the overlay
  defines its own nominal types.

Combine code is conditionally compiled on platforms that provide Combine. Linux verification
covers callbacks and async sequences; Apple-platform compilation and Combine execution require an
Apple SDK.

## Closing the remaining gaps

Each group above has a concrete route. The core routes need new public API in SQLiteOrbit, which
this overlay deliberately avoided; the overlay routes need none.

- **TransactionObserver** (largest remaining group): add an optional hooks group to `SQLiteLibrary`
  (`sqlite3_update_hook`, `sqlite3_commit_hook`, `sqlite3_rollback_hook`, optionally
  `sqlite3_preupdate_hook`) and a scoped registration on `SQLiteScopedAccess`. The overlay already
  owns per-connection state and every transaction boundary it starts, so `databaseWillCommit`,
  `databaseDidCommit`, and extents map directly. An overlay-only alternative is TEMP triggers that
  call a custom function, but they leak into `sqlite_temp_schema` and must track new tables, so they
  were not adopted.
- **Raw transaction SQL**: a core API to begin a managed transaction that ends on a later `COMMIT`/
  `ROLLBACK` statement on the same access would unlock `beginTransaction`, `commit`, and the raw-SQL
  transaction tests.
- **Concurrent pool reads**: let core pool readers proceed during a write (WAL snapshot isolation)
  instead of waiting at the write barrier; `spawnConcurrentRead` then maps onto a reader that begins
  its transaction before the writer's next commit.
- **ValueObservation per-commit delivery**: offer an observation mode that fetches once per commit
  and performs the initial fetch synchronously in `start`, either in the core or as per-subscription
  runtimes in the overlay (at the cost of the shared-runtime behavior documented above).
- **StatementColumnConvertible**: the overlay's raw read path already holds library statement
  handles, so it can lend `sqliteStatement` to `init(sqliteStatement:index:)` for read-only fetches;
  binding (`bind(to:at:)`) and write statements would need the core to lend prepared statements.
- **FTS5 tokenizers, backup, double-quoted strings, argument limits**: add `bindPointer`,
  `sqlite3_backup_*`, `sqlite3_db_config`, and `sqlite3_limit` entries to the library table.
- **Vacuum**: a managed `vacuum`/`vacuum(into:)` operation in the core connection that suspends the
  transaction guard for that statement only.
- **Small overlay-only items**: `lastErrorCode`/`lastErrorMessage` through the library's error
  functions, `readQoS`/`writeQoS` storage, `Cursor.dropLast()`, `DatabaseSchemaID.main`/`.temp`/
  `.attached`, and identifier case in region descriptions.

## Verification

```sh
swift test                                                   # whole package
swift test --filter SQLiteOrbitGRDBTests                     # overlay integration tests
python3 -I Tests/GRDBReference/grdb_upstream.py run --verify # upstream port, one process per class
Tests/GRDBReference/run.sh                                   # the same tests against GRDB itself
```

A broad `--filter` that matches every upstream test exceeds the kernel's argument-length limit on
Linux, so use `run --verify` (or no filter) for the upstream target.

`Tests/SQLiteOrbitGRDBTests` holds integration tests for native driver access, mixed native and
overlay writes, migrations, region tracking, cancellation, pool connection preparation, Codable
storage, and IPC peer observation, plus shared application fixtures in `Upstream/` that also run
against GRDB. The compatibility expansion measured above added no SQLiteOrbit (core) public API.
