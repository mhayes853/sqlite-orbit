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
| Access | Sync/async `read`, `write`, `unsafeRead`, `writeWithoutTransaction`; callback `asyncRead`, `asyncUnsafeRead`, `asyncWrite`, and `asyncWriteWithoutTransaction`; queue `inDatabase`; explicit transactions and savepoints. |
| Configuration | Foreign keys, busy timeout/callback, maximum reader count, per-connection `prepareDatabase`, and selection of a native SQLiteLibrary. |
| SQL | Multi-statement `execute(sql:arguments:)`, `execute(literal:)`, interpolation (including identifiers and SQL fragments), SQL composition/building, positional/named/numbered arguments, checked/unchecked statement arguments, and prepared/cached statements. |
| Values and rows | DatabaseValue and result codes, scalar conversions, Date/Data/UUID/URL conversions, owned rows, typed/raw column access, case-insensitive lookup, null inspection, row coalescing, lazy cursors, set fetching, cursor transformations/reductions, and cursor-to-collection construction. |
| Row adapters | Custom RowAdapter conformances and layout protocols, ColumnMapping, RenameColumnAdapter, EmptyRowAdapter, RangeRowAdapter, SuffixRowAdapter, splittingRowAdapters, ScopeAdapter, addingScopes, scopes/scopesTree, unscoped/unadapted, and scoped record decoding. |
| Records | FetchableRecord, EncodableRecord, TableRecord, PersistableRecord, MutablePersistableRecord, PersistenceContainer, generated IDs, save/insert/update/delete/exists, change dictionaries, change-only updates and returning updates, conflict policies, UPSERT, INSERT/UPDATE/SAVE RETURNING, and persistence callbacks. |
| Codable | Per-column date/data/UUID encoding and date/data decoding strategies, column name strategies, scalar Codable enums, JSON fields, JSON encoder/decoder customization, and nested records/keyed containers from row scopes. |
| Queries | SQLRequest, Table, Column/ColumnExpression, SQLSpecificExpressible, bound value expressions, predicates, key/ID filtering, array/SQL/literal selections and predicates, annotations, deferred primary-key selection/ordering/grouping, connection-dependent derivation, ordering, limits/offsets, distinct/group/having, typed ordering reversal, range predicates, SQL function expressions including coalesce, LIKE/ESCAPE, bitwise/unary/null-safe identity operators, compound column assignments, counts, bulk update/delete, and bulk UPDATE/DELETE RETURNING. |
| Schema | Table/column/index/view creation, generated columns, partial/expression indexes, constraints/defaults/foreign keys, common ALTER operations, schema-qualified table/view/trigger existence, columns (including generated columns), primary keys, indexes, foreign keys, unique-key checks, foreign-key violations/checks, and schema versions. |
| Migrations | Registration, sync/async migration, callback `asyncMigrate`, migration targets, applied/completed history, superseded checks, deferred foreign-key checks, and development schema reset. History uses `grdb_migrations`. |
| Observation | Dynamic tracking, inferred/explicit constant regions, callbacks, asynchronous sequences, immediate/main-actor/dispatch-queue scheduling, map/removeDuplicates, event hooks, cancellation, and conditional Combine publishers. |
| Connection setup | Custom scalar functions, aggregates, named built-in collations, and custom collations, including installation on every pool connection through prepareDatabase. |
| Maintenance | WAL checkpoints with passive/full/restart/truncate modes, schema selection, and frame counts. |

Rows fetched by `fetchAll` and `fetchOne` own their values. A row cursor reuses its current `Row`;
call `copy()` before retaining a row across cursor advances. Connections, cursors, and statements
must be used within their access closure. The overlay checks connection lifetime and thread
confinement and closes outstanding statements before returning a borrowed connection.

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
subscriber leaves.

UPSERT uses SQLite's atomic `ON CONFLICT DO UPDATE` and reports the rowid of the inserted or
updated row to insertion callbacks. It supports conflict targets, explicit assignments with the
`excluded` alias, and the `.noColumnUnlessSpecified` update strategy. Tables without rowids are
supported. Returning persistence APIs execute SQL `RETURNING`, so defaults and generated columns
are available and returned values precede changes made by AFTER triggers, as in SQLite and GRDB.
Both record-returning and selection/statement-fetch forms are available for insert, update, and
save; updates can restrict columns. Statements are consumed to completion before success callbacks.
These APIs require a selected engine with the corresponding UPSERT/RETURNING support.

Bulk requests support `updateAll(_:onConflict:_:)` with array or variadic assignments, and
`TableRecord.updateAll` forwarding. `updateAndFetchAll/Set/Cursor` and
`deleteAndFetchAll/Set/Cursor` return records using the decoder's `databaseSelection`, independently
of the request's selection. `deleteAndFetchIds` returns a set of IDs from a single-column primary
key. `updateAndFetchStatement` and `deleteAndFetchStatement` accept explicit returned selections,
including expressions and aliases, for scalar or row fetching. Assignments accept `.set(to:)`
and `+=`, `-=`, `*=`, `/=`, `&=`, `|=`, `<<=`, and `>>=`. Typed `$0.column` closure overloads
require the unimplemented DatabaseComponents DSL.

Bulk mutations bypass per-record persistence callbacks and use the record type's update conflict
policy unless explicitly overridden. Native observation and IPC announcements still apply.
`updateAll` with no assignments returns zero without database access; returning updates require
nonempty assignments and selections. Preparing a statement or cursor does not execute it.
Arrays and sets consume the statement to completion. Returned rows have no guaranteed order.
SQLite performs all matching mutations on the first step of a RETURNING statement; consuming
one returned row does not limit how many rows are changed. Exhaust or release cursors before
leaving their database access. Decoding errors do not undo statement changes by themselves;
letting the error escape a transactional `write` rolls back the transaction.

`DatabaseAggregate` forwards group state and errors to Orbit's native aggregate implementation.
Aggregate support depends on the selected engine. `Database.checkpoint(_:on:)` uses Orbit's native
checkpoint implementation, including its busy policy. Invoke it through `writeWithoutTransaction`;
SQLite may reject a checkpoint with an active transaction or statement. The compatibility default
schema is `"main"`; explicitly pass `nil` to checkpoint all attached schemas.

Schema inspection follows temporary, main, and attached schema resolution. Expression indexes are
excluded from `IndexInfo`, matching GRDB 7.11.1's representation. Foreign keys with omitted target
columns resolve against the destination primary key. Metadata is queried through native SQL access.
Typed ordering expressions support `reversed()` and NULL placement. Raw ordering SQL cannot be
reversed; use an SQL expression for reversible ordering.

Row adapters reshape fetched rows without changing the executed SQL. SQL and statement fetching
accept `adapter:` for rows, records, and scalars (including cursor and set fetching). Scalar fetches
read the first adapted column. `SQLRequest` accepts a mutable adapter, and `FetchRequest.adapted`
builds an adapter inside the eventual database access. Chained adaptations resolve against the
previous column mapping, matching GRDB. `PreparedRequest` carries the statement, bound arguments,
and adapter; the default preparation hook preserves existing `sql(in:)` request conformances.

```swift
let request = SQLRequest<Row>(sql: """
  SELECT player.id, player.name, team.id, team.name
  FROM player LEFT JOIN team ON team.id = player.teamId
  """, adapter: ScopeAdapter(base: EmptyRowAdapter(), scopes: [
    "player": RangeRowAdapter(0..<2),
    "team": RangeRowAdapter(2..<4)
  ]))

try database.read { db in
  if let row = try request.fetchOne(db) {
    let player: Player = try row.decode(forKey: "player")
    let team: Team? = try row.decodeIfPresent(forKey: "team")
    // Use player and its optional joined team.
  }
}
```

Scopes are case-sensitive. `scopes` looks up direct children, while `scopesTree` and scoped record
decoding search breadth-first. Optional scoped records are nil for missing or entirely NULL scopes;
`containsNonNullValue` also examines nested scopes. Synthesized Decodable properties can consume
scopes, and nested FetchableRecord types retain their own row initializer and decoding strategies.
A column takes precedence when it shares a coding key with a scope. Plain nested Decodable values
use their own column names; column decoding strategies do not rename scopes.

`unscoped` removes scopes while retaining the column projection; `unadapted` exposes the original
columns. Adapted cursors reuse their rows, including scoped views, until copied. `copy`, `fetchOne`,
and `fetchAll` preserve independent values and nested scopes after the access ends. Equality includes
scopes. Adapters resolve once per cursor, before stepping, so a failed column mapping or throwing
adapter does not execute a RETURNING mutation. Out-of-bounds range/suffix adapters are programmer
errors, as in GRDB. Custom adapters use the public underscored layout protocols; as in GRDB 7.11.1,
the concrete layout mapping initializer is internal, so they can delegate to built-in adapters.
These features use only Orbit's existing public API and work with the same drivers and observations.

## Compatibility boundaries

This is a supported subset, not complete GRDB protocol or behavior parity:

- Orbit's pool writes remain barriers against that pool's reads. GRDB's pool can overlap reads and
  writes. Turso's explicitly concurrent write APIs remain native APIs.
- Pool readers are opened eagerly. `maximumReaderCount` maps to Orbit's fixed reader count.
- Explicit write transactions support DEFERRED, IMMEDIATE, and EXCLUSIVE through native managed transactions.
- Values decode through DatabaseValueConvertible; GRDB's optimized StatementColumnConvertible
  coercions and its custom conformances are not implemented.
- Ungrouped bulk writes ignore ordering unless a limit is present, matching GRDB. Direct limited
  writes require SQLite's ENABLE_UPDATE_DELETE_LIMIT compilation option. GRDB 7.11.1 appends
  RETURNING after LIMIT; engines that reject that grammar also reject these limited returning
  requests before mutation, even when ordinary limited writes work.
- Bulk grouping is supported for column expressions that contain a unique key, including unary
  negation and collated columns. These requests use a key subquery, preserving HAVING, ordering,
  and limits without requiring UPDATE/DELETE LIMIT support. Composite WITHOUT ROWID keys use tuple
  subqueries; GRDB 7.11.1 does not implement this case. Other grouped bulk requests are rejected
  before mutation. The overlay throws an error for invalid grouping where GRDB uses a precondition.
- Dependencies that expose types from the original GRDB module require corresponding source
  changes; the overlay defines its own nominal types.
- Query association/join/prefetch APIs, prefetched row collections, Record class APIs, custom observation
  reducers, the explicit `SharedValueObservation` API, write-access observations, snapshots, backup, vacuum,
  explicit close, interrupt, specialized FTS helpers, and broad reactive access APIs remain future work.
- Explicit nested Codable encoding containers require a custom PersistenceContainer encoder.
  Decoding supports named row scopes and JSON columns; prefetched collection decoding remains future work.
- Default Unicode functions/collations supplied by GRDB are not automatically installed.
- Schema inspection covers ordinary tables/views and common primary keys; advanced schema metadata
  APIs remain future work.
- The selected engine must implement the operations used by an application. Turso has different
  capabilities, including unavailable deferred foreign-key checks. Use immediate migration checks
  or explicitly disable deferred checks there.

The convenience API audit also covers cursor sequence/iterator initializers, lazy prefix/drop/flatten
operations, extrema and reductions, and construction of arrays, sets, and dictionaries from cursors.
Cursor transformations return `AnyCursor`; GRDB's concrete adapter cursor types are not provided.
The custom `Cursor.forEach` implementation is preserved through mapping, filtering,
and enumeration; collection construction honors it as well. `Cursor.isEmpty` consumes its first element when present, as in GRDB.

Primary-key derivations resolve metadata inside the eventual database access. Creating such a
request does not open a connection or require that the table already exists. Replacing its selection,
ordering, or grouping also replaces the corresponding deferred derivation. Record change helpers
compare encoded database values and skip persistence callbacks and SQL when nothing changed.

DDL expressions and view definitions render bound values as SQL literals using the selected
engine's quoting function. The existing SQL tokenizer distinguishes parameters from quoted text,
identifiers, and comments. Generated columns and partial/expression indexes require engine support.

The audit deliberately leaves larger SQL/query features (associations, CTEs, JSON/FTS
DSLs, and custom reducers) for separate work. They are not simple forwarding conveniences even when
some can be built using the current native API. Vacuum was tested but deferred: SQLite's internal
transaction control is rejected by Orbit's guard outside a managed transaction (`SQLITE_AUTH`).
It needs coordinated support in native connection execution; the overlay does not bypass that guard.
No SQLiteOrbit native public API changes were made for this convenience expansion.

Combine code is conditionally compiled on platforms that provide Combine. Linux verification
covers callbacks and async sequences; Apple-platform compilation and Combine execution require an
Apple SDK.

## Verification

The package includes maintained fixtures derived from GRDB 7.11.1's argument, database-value,
Codable encoding, row/adapters, cursor, record-change, and foreign-key violation tests, plus shared application fixtures. Their provenance and
MIT license are in `Tests/SQLiteOrbitGRDBTests/Upstream`. The same fixtures run against GRDB itself
in a separate test package, so the main package does not resolve or link GRDB.

```sh
swift test --filter SQLiteOrbitGRDBTests
Tests/GRDBReference/run.sh
swift test
```

The additional integration tests exercise native driver access, mixed native/overlay writes,
transaction rollback, migrations, region tracking, cancellation, pool connection preparation,
Codable storage, and IPC peer observation. These tests establish compatibility for the covered
cases; they do not establish compatibility with the entire upstream GRDB test suite.
