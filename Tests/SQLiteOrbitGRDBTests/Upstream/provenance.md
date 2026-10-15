# GRDB verification fixtures

Upstream: groue/GRDB.swift tag v7.11.1, commit
b83108d10f42680d78f23fe4d4d80fc88dab3212, under the accompanying MIT license.

The import changes to SQLiteOrbitGRDB, and trailing whitespace is removed. GRDBTestCase supplies
an in-memory database instead of the upstream general harness. Test bodies retain their upstream assertions.

- Core/Statement/StatementArgumentsTests.swift: all 17 tests.
- Core/DatabaseValueTests.swift: all 5 tests.
- Record/PersistableRecord/DatabaseColumnEncodingStrategyTests.swift: all 2 tests.
- Record/PersistableRecord/DatabaseDataEncodingStrategyTests.swift: 3 encoding tests; query/trace tests
  after the Filter section are outside this fixture.
- Record/PersistableRecord/DatabaseDateEncodingStrategyTests.swift: 8 encoding tests; query/trace
  tests after the Filter section are outside this fixture.
- Record/PersistableRecord/DatabaseUUIDEncodingStrategyTests.swift: 3 encoding tests.
- Core/Row/RowFromDictionaryLiteralTests.swift: 10 column order, duplicate names, count, lookup,
  values, copy, and equality tests. Row-adapter/scoping and specialized conversion cases are excluded.
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
ConvenienceSurfaceTests.swift are additional shared application fixtures, not copied upstream.
They check callback order, save fallback, bounded bulk writes,
composite keys, intersecting filters, transaction modes, set/key fetching, request reversal,
RETURNING values and callbacks, UPSERT, schema resolution, aggregates, WAL checkpoints, request
conveniences, deferred derivation, record changes, DDL value quoting, schema builders, collations,
and SQL composition.
Observation lifecycle tests live outside this shared fixture directory because Orbit shares runtimes by definition and database, whereas
GRDB starts separate runtimes by default.

Run these 135 identical test bodies against GRDB itself with:

    Tests/GRDBReference/run.sh

The runner generates an ignored reference Sources directory with @testable imports so the original
encoding tests can construct GRDB's internal PersistenceContainer initializer.
