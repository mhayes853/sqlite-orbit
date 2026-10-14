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
writer to conform to Orbit's public `SQLiteDatabaseMetadata` protocol. No database access is performed to retrieve metadata.
Native drivers also expose their native `configuration`. Use `any DatabaseReader` or an
`AnyDatabaseReader` wrapper when requesting GRDB-shaped configuration properties.

## Covered surface

| Area | Implemented APIs |
| --- | --- |
| Access | Sync/async `read`, `write`, `unsafeRead`, `writeWithoutTransaction`; `asyncRead`; queue `inDatabase`; explicit transactions and savepoints. |
| Configuration | Foreign keys, busy timeout/callback, maximum reader count, per-connection `prepareDatabase`, and selection of a native SQLiteLibrary. |
| SQL | Multi-statement `execute(sql:arguments:)`, `execute(literal:)`, interpolation, positional/named/numbered arguments, checked/unchecked statement arguments, and prepared/cached statements. |
| Values and rows | DatabaseValue and result codes, scalar conversions, Date/Data/UUID/URL conversions, owned rows, typed/raw column access, case-insensitive lookup, lazy cursors, and cursor mapping/filtering. |
| Records | FetchableRecord, EncodableRecord, TableRecord, PersistableRecord, MutablePersistableRecord, PersistenceContainer, generated IDs, save/insert/update/delete/exists, change updates, conflict policies, and persistence callbacks. |
| Codable | Per-column date/data/UUID encoding and date/data decoding strategies, column name strategies, scalar Codable enums, JSON fields, and JSON encoder/decoder customization. |
| Queries | SQLRequest, Table, Column/ColumnExpression, predicates, key/ID filtering, selections, ordering, limits/offsets, distinct/group/having, counts, and bulk update/delete. |
| Schema | Table/column/index creation, constraints/defaults/foreign keys, common ALTER operations, table/view existence, column inspection, and primary-key inspection. |
| Migrations | Registration, sync/async migration, migration targets, applied/completed history, superseded checks, deferred foreign-key checks, and development schema reset. History uses `grdb_migrations`. |
| Observation | Dynamic tracking, inferred/explicit constant regions, callbacks, asynchronous sequences, immediate/main-actor/dispatch-queue scheduling, map/removeDuplicates, event hooks, cancellation, and conditional Combine publishers. |
| Connection setup | Custom scalar functions and collations, including installation on every pool connection through prepareDatabase. |

Rows fetched by `fetchAll` and `fetchOne` own their values. A row cursor reuses its current `Row`;
call `copy()` before retaining a row across cursor advances. Connections, cursors, and statements
must be used within their access closure. The overlay checks connection lifetime and thread
confinement and closes outstanding statements before returning a borrowed connection.

Observation uses native authorizer/cache metadata. Native writes and overlay writes affect the same
tracked regions. Explicit constant regions resolve inside the first observation read, avoiding a
blocking read when an async sequence is constructed. An observation can coalesce intermediate
changes; use `removeDuplicates` when equal fetched values should be suppressed.
Each subscription or async iterator starts its own observation runtime, with independent reducer
state and lifecycle callbacks, matching GRDB even though native Orbit observations share runtimes.

## Compatibility boundaries

This is a supported subset, not complete GRDB protocol or behavior parity:

- Orbit's pool writes remain barriers against that pool's reads. GRDB's pool can overlap reads and
  writes. Turso's explicitly concurrent write APIs remain native APIs.
- Pool readers are opened eagerly. `maximumReaderCount` maps to Orbit's fixed reader count.
- Explicit write transactions support DEFERRED, IMMEDIATE, and EXCLUSIVE through native managed transactions.
- Values decode through DatabaseValueConvertible; GRDB's optimized StatementColumnConvertible
  coercions and its custom conformances are not implemented.
- Ordered/limited bulk writes require SQLite's ENABLE_UPDATE_DELETE_LIMIT compilation option,
  as in GRDB. Unsupported engines and grouped bulk requests reject the write before mutation.
- Dependencies that expose types from the original GRDB module require corresponding source
  changes; the overlay defines its own nominal types.
- Query association/join/prefetch APIs, row adapters/scopes, Record class APIs, custom observation
  reducers, shared observations, write-access observations, snapshots, backup, explicit close,
  interrupt, specialized FTS helpers, and broad reactive access APIs remain future work.
- Custom explicit nested Codable containers require a custom PersistenceContainer encoder or row
  initializer. Normal synthesized nested properties use JSON columns.
- Default Unicode functions/collations supplied by GRDB are not automatically installed.
- Schema inspection covers ordinary tables/views and common primary keys; advanced schema metadata
  APIs remain future work.
- The selected engine must implement the operations used by an application. Turso has different
  capabilities, including unavailable deferred foreign-key checks. Use immediate migration checks
  or explicitly disable deferred checks there.

Combine code is conditionally compiled on platforms that provide Combine. Linux verification
covers callbacks and async sequences; Apple-platform compilation and Combine execution require an
Apple SDK.

## Verification

The package includes maintained fixtures derived from GRDB 7.11.1's argument, database-value,
Codable encoding, and row tests, plus shared application callback fixtures. Their provenance and
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
