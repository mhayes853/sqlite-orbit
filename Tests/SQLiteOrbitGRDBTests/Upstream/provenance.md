# Shared GRDB application fixtures

These fixtures are not copied from GRDB. They are application scenarios written for the overlay,
compiled against both SQLiteOrbitGRDB and GRDB 7.11.1 (`Tests/GRDBReference/run.sh`) so that GRDB
itself confirms each expectation. GRDB's own test suite is ported separately, verbatim, into
`Tests/SQLiteOrbitGRDBUpstreamTests` (see `Tests/GRDBReference/grdb_upstream.py`); earlier partial
copies of upstream files that used to live here were removed once the full upstream files were
ported and passing.

GRDBTestCase supplies in-memory queues and temporary file-backed pools. The fixtures check callback
order, save fallback, bounded bulk writes, composite keys, intersecting filters, transaction modes,
set/key fetching, request reversal, RETURNING values and callbacks, UPSERT, schema resolution,
aggregates, WAL checkpoints, request conveniences, deferred derivation, record changes, DDL value
quoting, schema builders, collations, SQL composition, null inspection, row reuse and copying,
bitwise and unary operators, optional comparisons, null-safe identity, LIKE/ESCAPE, expression
initialization, SQL coalescing, commit/rollback completion, deferred commit errors, non-Sendable and
optional results, partial writes outside transactions, callback scheduling, nontransactional reads,
migration callbacks, and row adapters with scoped records.

BulkPersistenceTests.swift uses GRDB's Record/TableRecord/TableRecordUpdateTests.swift and
TableRecordDeleteTests.swift as references. RowAdapterSurfaceTests.swift covers all adapted
fetching families, scoped required/optional records, nested Decodable values, custom adapters
through the public layout protocols, and adaptation of RETURNING results before mutation.

Native-only behavior (observation lifecycles shared per definition and database, IPC, Turso,
composite WITHOUT ROWID grouping that GRDB does not implement) is tested outside this directory.
The shared XCTest factories use SQLite-specific configuration, including trusted-schema control, so
their overlay runs use system SQLite or SQLCipher.

The MIT license in this directory covers GRDB material referenced by these fixtures.
