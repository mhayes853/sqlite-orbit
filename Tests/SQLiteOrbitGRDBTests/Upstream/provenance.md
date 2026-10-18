# GRDB verification fixtures

Upstream: groue/GRDB.swift tag v7.11.1, commit
b83108d10f42680d78f23fe4d4d80fc88dab3212, under the accompanying MIT license.

The import changes to SQLiteOrbitGRDB, and trailing whitespace is removed. GRDBTestCase supplies
in-memory queues and temporary file-backed pools instead of the upstream general harness. The
callback writer test class has an unchecked Sendable conformance for Swift 6 XCTest's
main-actor expectation wait. XCTest runs these synchronous test bodies on the main thread.
Test bodies retain their upstream assertions.

- Core/Statement/StatementArgumentsTests.swift: all 17 tests.
- Core/DatabaseValueTests.swift: all 5 tests.
- Record/PersistableRecord/DatabaseColumnEncodingStrategyTests.swift: all 2 tests.
- Record/PersistableRecord/DatabaseDataEncodingStrategyTests.swift: 3 encoding tests; query/trace tests
  after the Filter section are outside this fixture.
- Record/PersistableRecord/DatabaseDateEncodingStrategyTests.swift: 8 encoding tests; query/trace
  tests after the Filter section are outside this fixture.
- Record/PersistableRecord/DatabaseUUIDEncodingStrategyTests.swift: 3 encoding tests.
- Core/Row/RowFromDictionaryLiteralTests.swift: 12 column order, duplicate names, count, lookup,
  values, copy, equality, description, and coalescing tests. Row-adapter/scoping and specialized
  conversion cases are excluded.
- Core/Row/RowFromDictionaryTests.swift, RowFromStatementTests.swift, and
  RowCopiedFromStatementTests.swift: one coalescing test each.
- Core/DatabaseWriterTests.swift: 4 callback write tests, each exercising queues and pools.
- Core/Cursor: all tests in AnyCursorTests, CursorTests, DropFirstCursorTests,
  DropWhileCursorTests, EnumeratedCursorTests, FilterCursorTests, FlattenCursorTests, MapCursorTests,
  PrefixCursorTests, and PrefixWhileCursorTests (52 tests). DatabaseCursorTests requires specialized
  cursor/profiling APIs and is outside this fixture.
- Core/ForeignKeyInfoTests.swift: 5 foreign-key violation/check tests, including unknown/main schema
  resolution and rich error messages. Attached-file tests use a different upstream harness.
- Record/PersistableRecord/MutablePersistableRecordChangesTests.swift: 4 tests for unchanged records
  and change dictionaries on classes/structs. SQL-trace and Record-class tests are outside this fixture.

Source files: https://github.com/groue/GRDB.swift/tree/v7.11.1/Tests/GRDBTests

PersistenceCallbackTests.swift, ScopedWriteTests.swift, ExpandedSurfaceTests.swift, and
ConvenienceSurfaceTests.swift, SmallConvenienceTests.swift, AsyncWriteSurfaceTests.swift, and
AsyncReadAndMigrationTests.swift, and BulkPersistenceTests.swift
are additional shared application fixtures, not copied upstream.
They check callback order, save fallback, bounded bulk writes,
composite keys, intersecting filters, transaction modes, set/key fetching, request reversal,
RETURNING values and callbacks, UPSERT, schema resolution, aggregates, WAL checkpoints, request
conveniences, deferred derivation, record changes, DDL value quoting, schema builders, collations,
and SQL composition. The small convenience and callback fixtures additionally check null
inspection, row reuse/copying, bitwise and unary operators, optional comparisons, null-safe
identity, LIKE/ESCAPE, expression initialization, SQL coalescing, commit/rollback completion,
deferred commit errors, non-Sendable and optional results, and partial writes outside transactions.
The read/migration fixtures check callback scheduling, nontransactional reads, migration completion
with write access, chained and already-applied migrations, migration rollback/history, and SQL errors.
They use GRDB's unsafe-read contract and migration callback scenarios as their reference.
BulkPersistenceTests.swift uses Record/TableRecord/TableRecordUpdateTests.swift and
TableRecordDeleteTests.swift as references for assignment overloads, conflict defaults/overrides,
returning records and explicit selections, prepared statement/cursor execution, decoding failures,
trigger/generated values, unique-key grouping, view counts, virtual tables, and engine-dependent
limits. These are shared application fixtures, not copied upstream test bodies. The native-only
bulk tests additionally cover rejected grouping, resolver evaluation counts, scope checks, IPC
observation with partial cursors, and composite WITHOUT ROWID grouping (unsupported by GRDB).
Observation lifecycle tests live outside this shared fixture directory because Orbit shares runtimes by definition and database, whereas
GRDB starts separate runtimes by default.

Run these 176 identical test bodies against GRDB itself with:

    Tests/GRDBReference/run.sh

The runner generates an ignored reference Sources directory with @testable imports so the original
encoding tests can construct GRDB's internal PersistenceContainer initializer.
