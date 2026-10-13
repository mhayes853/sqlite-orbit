# Benchmarks

A port of GRDB's performance suite
([`Tests/Performance/GRDBPerformance`](https://github.com/groue/GRDB.swift/tree/master/Tests/Performance/GRDBPerformance))
to [package-benchmark](https://github.com/ordo-one/package-benchmark), measuring sqlite-orbit
against GRDB and the SQLite C API on the same fixture.

This is a package of its own, so package-benchmark and GRDB never enter the library's dependency
graph. Run it from this directory:

```sh
swift package --allow-writing-to-package-directory benchmark --target FetchBenchmarks
swift package --allow-writing-to-package-directory benchmark --target InsertBenchmarks

# One group at a time
swift package --allow-writing-to-package-directory benchmark --target InsertBenchmarks \
  --filter 'InsertPositionalValues/.*'

# Compare a change against a saved run
swift package --allow-writing-to-package-directory benchmark baseline update main
swift package --allow-writing-to-package-directory benchmark baseline compare main
```

The first build compiles swift-syntax in release mode and takes several minutes.

## Layout

| Target | Contents |
| --- | --- |
| `FetchBenchmarks` | Reading 200,000 rows: by position, by name, into records, and dates; plus per-read access overhead and 100,000 one-row lookups by rowid. |
| `InsertBenchmarks` | Writing 50,000 rows: by position, by name, from records; 1,000,000 bound strings; plus per-write access overhead. |
| `BenchmarkSupport` | The fixture, the shared configuration, and a raw C connection. |
| `CSQLiteBenchmark` | The SQLite C API, for the baseline every group is measured against. |

Benchmarks are named `<GRDB test>/<implementation>`, so a group's rows sit together in the output.
Implementations are `SQLite` (the C API), `GRDB`, `Orbit` (a synchronous `SQLiteConnection`), and
`OrbitQueue`, `OrbitPool`, or `OrbitIPC` for the asynchronous drivers. Orbit's `execute` and
cursors reuse statements from the connection's prepared statement cache, as they do by default;
`OrbitUncached` runs the same SQL with `cached: false`, preparing each statement anew, and
`OrbitPrepared` prepares one `SQLitePreparedStatement` and runs it with each row's arguments, as the
SQLite and GRDB rows reuse theirs. Groups GRDB has and Orbit has no counterpart for, such as
`FetchRecordClass` and `InsertNamedValues`, are kept for parity with GRDB's own numbers.

## Fixture

The table is GRDB's: `item(i0 … i9 INT)`, where row `n` stores `n` in every column. Fetch groups
read a 200,000-row database written once with the C API, under the system temporary directory in
`sqlite-orbit-benchmarks`. Insert groups write 50,000 rows to a fresh database each iteration.
Every group runs 50 iterations, as GRDB's do, except `Arguments*`, which runs 10.

## Differences from GRDB's suite

- Every benchmark checks its result: fetches sum every value read and compare the sum, and
  inserts check the row count and extreme values afterwards. Summing also keeps the optimizer
  from discarding reads GRDB's tests leave unused.
- Insert iterations create their database, table, and connection before measurement starts, and
  verify and delete it after measurement stops, so only the inserting transaction is measured.
  GRDB's tests include opening the database and creating the table.
- `DateParsing` opens its in-memory database once rather than inside every iteration.
- `Arguments*` gives every iteration a fresh table and transaction, and adds C-level
  `SQLITE_STATIC` and `SQLITE_TRANSIENT` baselines.
- `Arguments*` also runs GRDB's ad-hoc paths, which hand it SQL for every row:
  `GRDBExecuteSQL` (`execute(sql:arguments:)`) and `GRDBLiteral` (`execute(literal:)`) prepare a
  statement every time, like `OrbitUncached`, and `GRDBCached` (`cachedStatement(sql:)`) reuses
  one from GRDB's opt-in cache, like `Orbit`. GRDB's own tests run one prepared statement, like
  `OrbitPrepared`.
- `FetchOneByRowID` has no GRDB counterpart. It makes 100,000 one-row lookups by rowid in one
  read, so the cost of running a statement dominates rather than of stepping rows, and runs each
  library's ways of doing so: prepared once (`SQLite`, `GRDBPrepared`, `OrbitPrepared`), cached
  (`GRDBCached`, `Orbit`), prepared per lookup (`SQLiteUncached`, `GRDB`, `GRDBLiteral`,
  `OrbitUncached`), and through a query builder (`GRDBQueryInterface`, `OrbitStructuredQueries`).
- `ReadAccessOverhead` and `AccessOverheadWrite` have no GRDB counterpart. They make 10,000
  separate one-row accesses to measure what an access costs apart from its query, comparing like
  drivers: `DatabaseQueue` with `SQLiteQueue`, `DatabasePool` with `SQLitePool`. Writes run with
  `synchronous = OFF` everywhere, so disk syncs do not hide the libraries' own cost.

Results vary with load, so compare runs from the same machine. Malloc counts are the steadiest
metric.
