**SQLiteOrbit API audit — 2026-10-04**

Follow-up status, 2026-10-06: the audit below describes the original revision. The branch has since
addressed correctness findings 1–3, connection ownership (4), scoped observation (5), stateful
reducers (6), writer coordination from 7, typed installation from 9, region serialization (10),
and grouped fetching (13). It also corrects cursor-cache documentation, exposes optional default
database lookup, reader mapping and opaque observation identity, and makes `onUpdate` the common
subscription callback primitive.

Further implemented: validated SQL parts (8), public request helpers and fetch/scheduler composition
(11–12), reader-based observability and public region-delivery guarantees (7), shared subscription
completion (15), explicit pool initializer counts, and removal of the instance `Table.databaseRegion`
convenience. Request helpers consistently use a `Request` suffix, including `sectionedRequest`.

Row mutation primitives (14) are now public too: primary-keyed tables expose transactional updates,
and row bindings compose public blocking mutation methods with the existing save-state behavior.

Migration policy/status (16) and managed authorization (9) are now public. Explicit migration
policies and a status snapshot preserve all existing GRDB-compatible entry points. Authorization
can be configured for every connection, replaced on a connection, or added for a synchronous scope.

Connection-setting effect boundaries are now explicit too: throwing setters apply busy-timeout
and foreign-key changes immediately, and the corresponding properties report applied values.

A second cleanup review at `df86b5f` fixed timeout saturation at the `Int32` millisecond boundary
and inconsistent hashing of type-erased values, shared SQL conversion and scheduler routing, and
removed redundant normalization and forwarding code. See the final section for newly reproduced
issues and API discussion points; those larger behavior changes remain unimplemented.

Audited revision: 650e459. The source inventory contains 149 Swift files and 30,174 lines, including comments. This review covers the database/SQLite layer, SQL and row conversion, cursors, observation, IPC, subscriptions, fetching and SwiftUI adapters, migration, suspension, macros, and test support. Three Sol agents reviewed separate areas; the primary review reconciled their findings against the source.

This is a source and test-code audit. No library implementation was changed, and no fresh build or runtime test suite was run. Behavioral findings below follow from the inspected implementation; suggested regression cases are listed at the end. SwiftUI and alternate SQLite trait configurations were inspected statically.

**Overall assessment**

The library has good low-level building blocks, but does not yet satisfy the goal that every high-level feature can be implemented using only public lower-level APIs. The biggest obstacles are connection ownership/lending, scoped observation, observation state factories, and fetch identity/lifecycle machinery.

Raw SQLite pointers and the public SQLiteLibrary function table are useful escape hatches. They are not substitutes for public Swift primitives that preserve lifetime, callback ownership, transaction notification, and error semantics. Requiring a caller to reproduce those mechanisms is precisely where this library currently gives itself capabilities unavailable to clients.

Conversely, the presence of internal members alone is not evidence of a design problem. A cursor should hide its lease and cache bookkeeping. The test is whether another module can build the same useful operation from a supported public primitive without accessing that bookkeeping.

| Layer | Public composition today | Main missing capability |
|---|---|---|
| SQL and value/row conversion | Mostly good | Lossless, validated SQL decomposition |
| Cursor algorithms and fetch helpers | Mostly good | Clear cache contract; optional prepared-statement access |
| SQLiteQueue / SQLitePool / TursoPool | Incomplete | Safe owned connection runner and lending |
| Configuration functions/collations | Incomplete | Typed installation on borrowed connection access |
| Value observation | Incomplete | Scoped observation, stateful reducer factory, explicit coordination capabilities |
| IPC database and custom transports | Incomplete | Scoped change capture and portable region representation |
| Fetch / FetchAll / FetchOne / sections | Incomplete | Shared request factories, compatible scheduler identity, section construction |
| Row / SingleRow SwiftUI bindings | Incomplete | Public mutation operations with the same lifecycle/error behavior |
| Migrator | Mostly composable | Scratch connection creation bypasses public ownership layer |
| Suspension, row/library macros, test trait | Good overall | No comparable missing foundational seam found |

**Correctness issues to address before API cleanup**

1. **An old fetch subscription can cancel a newer load.** The handle returned by a replacement load captures the storage and calls its unqualified detach operation. After loading A and then B, cancelling A detaches B. Repeated cancellation can affect later loads too. The token should capture a particular generation and cancel idempotently. This is a lifecycle defect, not just naming.

   Evidence: [load's returned token](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Internal/OrbitFetchStorage.swift:614), [cancel implementation](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/OrbitFetchSubscription.swift:35).

2. **Replacing a fetch request can lose the environment database.** Replacement load resolves an omitted database through defaultDatabase.current, without considering the database currently supplied by SwiftUI. A view using environment database A can switch to process default B; if there is no default, resolution can terminate the process. This conflicts with the documented three-place resolution model. Preserve the existing resolved context unless replacement explicitly chooses another database.

   Evidence: [replacement resolution](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Internal/OrbitFetchStorage.swift:618), [environment attachment](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Internal/OrbitFetchStorage.swift:637), [documented precedence](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/OrbitDefaultDatabase.swift:11).

3. **A write connection exposes mutation cursors despite documenting their prohibition.** SQLiteWriteConnection explains that it has no write cursors because partially consumed RETURNING statements have ambiguous commit-notification timing. Its read-query cursor nevertheless delegates to the write transaction's permissive cursor; the raw SQL overload explicitly allows writing. Unlike execute, that path does not flush pending commit notifications at statement completion. Source inspection indicates notification timing can slip to another operation or the end of the access.

   The smallest correction is to enforce read-only preparation for connection cursors outside explicit transactions. If mutation cursors are intended, introduce a statement lifecycle contract that publishes changes on completion/reset instead of relying on the current incidental path.

   Evidence: [connection contract](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteConnection.swift:173), [cursor delegation](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteConnection.swift:410), [execute's commit flush](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteConnection.swift:449). The existing [outside-transaction tests](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Tests/SQLiteOrbitTests/SQLite/SQLiteAccessWithoutTransactionTests.swift:125) cover execute notifications, not this mutation-cursor path.

**Public primitives with the highest value**

4. **Expose a safe owned connection runner.** SQLiteConnectionAccess and the native transactions are public borrowed types, but their constructors require the internal SQLiteHandle. Public setup APIs tell custom drivers to prepare and install a configuration, yet those drivers cannot create the access value needed for installation. The migrator itself opens an internal handle to build a scratch schema on the calling thread.

   Introduce a connection owner that opens/closes the handle and lends read/write connections and transactions through lifetime-bounded closures. It should support deliberate synchronous use and opening policy. SQLiteQueue and pools should build their scheduling around it. A documented serialized execution primitive can be added if clients need to reuse the dedicated-thread behavior.

   Do not solve this with unrestricted public pointer initializers for transactions. The owner should retain the library/configuration, establish callback context, enforce access rules, and preserve observation and settings behavior.

   Evidence: [unconstructible access value](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteLibrary.swift:724), [custom-driver setup instructions](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteConfiguration.swift:187), [migrator's privileged open](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Migration/OrbitDatabaseMigrator.swift:584), [queue's internal connection owner](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteQueue.swift:28). A public SQLiteQueue can perform equivalent scratch database work, but uses its own executor; it does not supply the same calling-thread mechanism.

5. **Expose access-scoped observation and derive region recording from it.** Automatic observation calls internal SQLiteReadTransaction.withObserver. IPC capture reaches through base.observations, including base.base.observations for write connections. Registering a global database observer is not equivalent: it can mix independent concurrent accesses.

   A public scoped observer operation on transactions/connections would support custom tracking, instrumentation, and change collectors. Public recordingReads/recordingChanges helpers could then return the operation's result and aggregate region. Define rollback and partial-commit behavior explicitly for connection access.

   Keep the observation context, locks, pending sets, and registry private.

   Evidence: [scoped transaction primitive](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteTransaction.swift:140), [automatic read capture](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Observation/OrbitValueObservation.swift:113), [IPC write capture](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/IPC/OrbitIPCDatabase.swift:543).

6. **Expose a stateful observation transform factory.** Public map/filter/compactMap can transform values, but cannot allocate operator state with the same lifetime as built-in removeDuplicates. The private mapReduction factory creates state per database runtime; capturing a variable in a public map/filter closure instead shares that state across runtimes or restarts.

   Publish a typed reducer/transform factory with explicit emit and skip results and a documented per-runtime lifetime. Implement map, filter, compactMap, and removeDuplicates through it. A typed transaction-filter composition primitive is also needed if arbitrary stateful transaction predicates are meant to be reproducible. Keep erased payloads and runtime implementation types private.

   Evidence: [private factory](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Observation/OrbitValueObservation.swift:588), [removeDuplicates state](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Observation/OrbitValueObservation.swift:674), [runtime construction](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Observation/OrbitValueObservation.swift:1295).

7. **Make observation requirements match actual capabilities.** OrbitObservableDatabase inherits OrbitDatabaseWriter although value observation requires reads and observer registration. Narrow observability to a reader plus subscription; require writing separately where Row, SingleRow, or IPC needs it. This enables read-only observable façades without fake write implementations.

   Two other hidden contracts affect higher observation. OrbitDatabaseCommit carries a private SQLitePoolWriterBarrier consumed by the refetch runtime. OrbitRegionSubscription privately indicates whether deliveries are filtered by region. Clients can conservatively reproduce some behavior, but cannot reproduce the same coordination and efficiency from the public event/subscription values.

   Expose a driver-neutral finite writer-cohort capability if coalescing is part of the promised public behavior, and a semantic subscription delivery guarantee. Preserve the finite cohort boundary so later writes cannot indefinitely extend a wait. Do not publish the pool scheduler or infer a permanent capability contract merely from whether a closure was supplied.

   Evidence: [observable protocol](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Observation/OrbitDatabaseTransactionObservation.swift:174), [hidden commit barrier](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Observation/OrbitDatabaseTransactionObservation.swift:30), [hidden region capability](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Subscription/OrbitRegionSubscription.swift:68), [region widening/catch-up logic](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Observation/OrbitValueObservation.swift:1984).

8. **Provide validated SQL decomposition.** Failed interpolated conversion is recorded as a private bindingFailure and a NULL placeholder. The public text and bindings do not describe that failure. An adapter that reconstructs SQL from those properties—or binds them through another API—can turn a query that should throw into one that runs with NULL.

   Add a throwing validatedComponents operation or a public binder that consumes the intact SQL value. Keep mutable failure storage private. This is particularly relevant to custom drivers and query adapters.

   Evidence: [hidden error state](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQL/SQL.swift:41), [NULL substitution on failure](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQL/SQL.swift:208), [native validation](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/Internal/SQLiteBinding.swift:1).

9. **Expose typed connection installation and managed authorization.** Configuration-level scalar functions, aggregates, and collations use internal Swift-to-C bridges. Clients get raw registration functions, but would need to rebuild callback retention, argument adaptation, results, errors, aggregate state, and thread-local library handling.

   Put typed installation operations on borrowed connection access; have configuration registration append setups that call them. Accept semantic function flags: the public flags include directOnly and innocuous, while typed registration accepts only isDeterministic. The bridge should retain its required UTF-8 convention.

   Authorization needs its own managed public operation. Setups explicitly forbid replacing the single authorizer, while the library has a private dispatcher. A scoped authorization policy must handle cached statements; just making the current dispatcher public would not establish that newly installed policies apply to previously prepared statements.

   Evidence: [typed registration](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteFunctions.swift:107), [internal callback bridge](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/Internal/SQLiteFunctionInstallation.swift:6), [restricted flag construction](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/Internal/SQLiteFunctionInstallation.swift:93), [public flags](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteResultCode.swift:182), [authorizer ownership rule](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteConfiguration.swift:157), [internal dispatcher](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/Internal/SQLiteAuthorizerDispatcher.swift:77).

10. **Make regions portable for custom transports.** The transport protocol is public, but an arbitrary region has no public lossless enumeration or serialization API. The built-in wire format reads internal table/default/complement data. A custom cross-process transport can conservatively announce the full database, but cannot preserve the same arbitrary regions using just the public surface.

Provide a transport-neutral region representation or codec, including exclusions such as “all tables except X” and “all columns except Y.” This need not freeze the Unix datagram envelope or expose the in-memory dictionary layout.

Evidence: [region representation](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Region/OrbitDatabaseRegion.swift:23), [private wire representation](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/IPC/UnixDatagram/Internal/UnixDatagramWireProtocol.swift:27).

**Simplifying the high-level surface**

11. **Unify fetch scheduling before deleting overloads.** Across Fetch, FetchAll, FetchAll+Sections, and FetchOne there are 55 public initializers and 31 public load declarations. Thirty-eight are animation-taking forwarding overloads. These counts include conditional SwiftUI declarations and were counted directly from the source.

| File | Initializers | load methods | Animation forms |
|---|---:|---:|---:|
| Fetch.swift | 7 | 5 | 5 |
| FetchAll.swift | 11 | 5 | 6 |
| FetchAll+Sections.swift | 12 | 8 | 10 |
| FetchOne.swift | 25 | 13 | 17 |
| Total | 55 | 31 | 38 |

Fetch requires a Hashable scheduler, but the public mainActor.animation scheduler is not Hashable. An internal fetch-specific animation scheduler supplies stable identity and different initial-delivery behavior. Therefore the apparent duplication hides a real lower-level mismatch.

Supply a public animation scheduler with suitable stable identity, or separate delivery from an explicit scheduler identity. Preserve the existing distinction between immediate and deferred initial delivery. Then most animation forms can be optional convenience forwarding through public API, rather than privileged implementations. Do not automatically remove overloads that solve genuine optional/scalar/tuple inference ambiguities.

Evidence: [fetch scheduler constraint](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Fetch.swift:143), [public transaction scheduler](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Observation/OrbitValueObservationScheduler+SwiftUI.swift:13), [internal animation scheduler](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Internal/OrbitFetchAnimationScheduler.swift:11).

12. **Make one fetch state/lifecycle layer serve all wrappers.** FetchAll and FetchOne separately reach into internal storage/state. Prefer a reusable public Fetch core, or a small public fetch handle underlying it, with request factories for all rows, an optional first row, and a required first row. Use those same requests in observation. Keep the ergonomic wrappers if they improve inference and declarations.

Separate query sharing identity from presentation identity. Request sharing currently includes the scheduler in its registry key; equal queries delivered differently therefore start separate observations. A public request-to-shared-observation factory should preserve sharing independently of how each subscriber delivers values. Keep weak boxes and the registry internal.

Small additions that help integrations are an opaque observation identity, optional default-database lookup, and map on OrbitFetchReader. None requires publishing the storage protocol.

Evidence: [sharing factory and source identity](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Internal/OrbitFetchStorage.swift:17), [scheduler in identity](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Internal/OrbitFetchStorage.swift:124), [reader projections](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/OrbitFetchReader.swift:66), [internal optional lookup](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/OrbitDefaultDatabase.swift:101).

13. **Move grouped fetching below FetchAll.** Public section collections can only be initialized empty or with one section. The multiple-section constructor and grouped decoder are internal. The decoder already supports generic Hashable keys, but public FetchAll section APIs fix keys to String?.

Expose a sectioned request/query operation usable in a transaction, observation, or fetch wrapper, plus a validated public collection constructor for grouped values and fixtures. Permit typed keys in the lower layer. Keep the index-compression representation and SQL rewrite helpers private.

Evidence: [collection construction](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/OrbitFetchSectionCollection.swift:30), [generic grouped decoder](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Internal/OrbitFetchSectionedRequests.swift:36), [String? query rewrites](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/FetchAll+Sections.swift:363).

14. **Make row bindings derive from public mutation operations.** SwiftUI bindings call internal blocking save/update operations that include database resolution and save-state/error handling. Row's transactional update helper is private, whereas singleton transaction operations have a public lower layer.

Publish the transaction-level row mutation capability. If synchronous binding writes remain intentional, provide deliberate public blocking row operations with the same state/error semantics. Do not silently replace these with detached asynchronous writes: that would change ordering and failure behavior. Their UI-blocking nature should remain clear in the API.

Evidence: [bindings](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Row+SwiftUI.swift:14), [hidden blocking and transactional row updates](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/Row.swift:157), [singleton operations](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/SingleRowTable.swift:62).

15. **Consolidate subscription lifetime semantics.** OrbitSubscription, OrbitRegionSubscription, and OrbitFetchSubscription represent different capabilities, so they need not be one type. They should share clear, idempotent cancellation behavior and compose from one cancellation primitive.

FetchSubscription.task specifically waits for cancellation of the surrounding task; calling cancel does not release that waiter. This matches its documentation, but is surprising for a member named task on a subscription. Prefer a named task-lifetime operation, or define an explicit completion operation that responds to subscription cancellation. Preserve the fact that ignoring a load's returned token currently leaves the property observing; replacing it with an automatically cancelling token without accounting for that would break discardable-result usage.

Evidence: [fetch task/cancel semantics](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Fetching/OrbitFetchSubscription.swift:12), [ordinary subscription](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Subscription/OrbitSubscription.swift:1).

16. **Replace migration mode state with explicit per-migration policy.** ForeignKeyChecks has immediate/deferred, while defersForeignKeyChecks=false actually selects an internal disabled mode for subsequently registered deferred migrations. It does not mean “check immediately,” and changing it after registration does not change existing migrations. The extra disablingDeferredForeignKeyChecks method duplicates the mutable property for compatibility.

Prefer one explicit per-migration policy expressing immediate checks, disabled-during-migration with validation before commit, and disabled without validation. Remove the temporal coupling between mutating a global flag and registering a migration. Retain compatibility forwarding only as a migration path if needed.

The five status queries are legitimate distinctions, but mostly derive from the registered identifiers and one applied-identifier read. A single status snapshot with computed registered/applied/pending/completed/superseded views is a smaller, more consistent high-level inspection surface. The GRDB table-name preset is harmless convenience and much lower priority.

Evidence: [registration captures policy](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Migration/OrbitDatabaseMigrator.swift:191), [duplicated compatibility method](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Migration/OrbitDatabaseMigrator.swift:213), [status queries](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Migration/OrbitDatabaseMigrator.swift:640).

**Secondary design improvements**

- SQLiteWriteConnection.isForeignKeysEnabled records desired state; its getter can reflect intent before SQLite has applied it, and the next unrelated statement receives an application error. A throwing setter or scoped settings operation would make the effect boundary clearer. Preserve restoration after a failed operation rather than naively making cleanup throw and mask the original error. [Settings API](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteConnection.swift:281).
- The cached cursor documentation says overlapping same-SQL cursors share one statement and are unsafe. Native checkout instead removes the idle statement and allocates another lease as needed. Correct that contract and treat caching as an optimization hint. A separate prepared-statement abstraction is a useful future extension for repeated binding and metadata, not a prerequisite for every convenience method. [Documented restriction](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Transaction/OrbitDatabaseTransaction.swift:52), [native checkout](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/Internal/SQLiteStatementCache.swift:46).
- Use the rich onUpdate subscription as observation's canonical callback primitive; derive onChange and value/change sequences from it. Keep successful suppressed-fetch completion, which Fetch already uses. [Public update subscription](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Observation/OrbitValueObservation.swift:893).
- Pool sizing lives in SQLiteConfiguration even though queue users do not use it. If configuration evolves, separate connection settings from pool scheduling settings rather than adding more ignored backend-specific fields. [Configuration](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/SQLite/SQLiteConfiguration.swift:31).
- The instance Table.databaseRegion ignores the instance and duplicates the static form. This is a reasonable deprecation candidate if unused. [Instance convenience](/home/whypeople/.t3/worktrees/sqlite-orbit/t3code-35327f65/Sources/SQLiteOrbit/Region/OrbitDatabaseRegion.swift:378).
- Public error snapshotting and borrowed column bytes would help custom native integrations. Treat these as follow-up capability requests, below the confirmed seams above; avoid exposing raw storage simply because it exists.

**What I would retain**

The four read/write transaction/connection views express real effect and lifetime distinctions. Async and blocking database access express different scheduling contracts. A missing row versus a required row is a real distinction. Raw SQL, row conversion, and structured queries serve different caller needs. Do not collapse these just to reduce declaration counts.

The row/cursor protocols already make many high-level algorithms possible from public requirements. The row macro generates public protocol conformances instead of depending on privileged client access. The library macro builds the public function table. The test trait uses public scoped default-database installation. Suspension adapters use OrbitSuspendable. These are useful examples to follow.

The public refetch-controller context is another good model: built-in strategies use public snapshot/wait/fetch operations. Keep that capability-oriented design rather than exposing the runtime's state machine.

Keep cache leases, pointer storage, callback boxes, column lookup caches, locks, weak registries, executor internals, revision counters, Unix endpoints, directory watchers, stale cleanup, and the datagram envelope private. Expose portable region semantics rather than the codec's memory layout. Concrete cursor overloads include explicit Swift compiler-workaround comments; do not remove them solely because equivalent protocol extensions exist.

**Suggested order and acceptance criteria**

1. Correct stale fetch cancellation, replacement database resolution, and write-connection cursor semantics.
2. Add safe connection lending, scoped observation, and validated SQL access. Rewrite existing implementations to use these public primitives.
3. Add typed installation/authorization, runtime-scoped reducers, portable regions, and explicit observation coordination contracts.
4. Unify fetch requests, identity, scheduler composition, and section fetching; make wrappers forward through the public core.
5. Simplify migration policy/status and deprecate redundant convenience overloads only after replacements preserve semantics and inference.

The strongest regression guard is an external-client conformance/composition target with ordinary import SQLiteOrbit, no @testable import, and no package access. Give that target small implementations of:

- A custom connection runner/driver using public setup and lending.
- Automatic read-region observation and an IPC change collector.
- A stateful observation operator, tested across two databases and a restarted runtime.
- A custom transport that round-trips inclusive and exclusion regions.
- A sectioned fetch with typed keys and constructed test fixtures.
- Fetch/row conveniences built only from public lower operations.

Add behavioral regressions for A-load/B-load/A-cancel, repeated cancellation, query replacement with only an environment database, mutation RETURNING cursors outside a transaction, SQL conversion-error preservation through adapters, and authorization installed after a statement has been cached.

The completion criterion is semantic: another module can reproduce the high-level operations with their lifetime, cancellation, region, error, and scheduling behavior intact. A smaller declaration count is useful only when that capability improves.


**Cleanup review — 2026-10-06**

Three Sol agents reviewed the SQLite/migration, fetching/query, and observation/IPC areas. The
primary review also checked shared utilities, macros, and the test-support boundaries. Safe changes
were committed separately as `f5f7315` (connection settings), `02d0da2` (queries/fetch identity), and
`2c270f9` (observation/regions). The test review removed the assertion that an idle serial queue
must return a nil writer barrier: an already-complete barrier is equally valid under the public
contract, and integration tests cover serial refetch behavior. Other reviewed lifecycle and error
tests cover distinct behaviors and were retained. One concurrency test now propagates errors it
previously discarded, and timeout boundary coverage extends the existing parameterized test.

The following behaviors were reproduced using temporary tests against public library APIs. These
reproductions were removed from the test target after validation, rather than making the current
bugs the expected behavior of permanent tests. Finding 1 remains open; the October 8 follow-up
resolves 2 and 3 and retains SQLiteData's existing behavior for 4, as noted below.

1. **Cached transaction control bypasses the outside-transaction restriction.** In a borrowed write
   connection, prepare and consume `rowCursor("SAVEPOINT cached", cached: true)` inside
   `connection.transaction`, and release that savepoint before the transaction commits. Consume the
   same cached cursor SQL after the transaction returns. It succeeds and native autocommit becomes
   false, despite the documented prohibition. Loan cleanup eventually rolls it back, but statements
   in the meantime no longer have the promised individual commit boundaries. The connection's
   commit-reporting logic assumes those boundaries. Cache hits bypass the preparation-time guard;
   enforcement must cover reuse as well as preparation.

   Evidence: [cache checkout](../Sources/SQLiteOrbit/SQLite/Internal/SQLiteStatementCache.swift),
   [outside-transaction guard and cleanup](../Sources/SQLiteOrbit/SQLite/SQLiteConnectionOwner.swift).

2. **A failed composite subscription update can lose commits from its reported region.** A custom
   multiprocess writer can return a region subscription that rejects updates. Start an
   `OrbitIPCDatabase` subscription for `items`, using the ordinary in-memory transport, then update
   it to `lists`. The transport and same-process registration change first; the writer throws last.
   The outer subscription still reports `items`, but subsequent peer commits to `items` disappear,
   while commits to `lists` arrive. Updating multiple sources needs an explicit failure policy:
   restoration, conservative over-subscription, or invalidation of the whole subscription. Changing
   their order alone does not resolve partial failures in general.

   Evidence: [composite update](../Sources/SQLiteOrbit/IPC/OrbitIPCDatabase.swift),
   [last-successful region contract](../Sources/SQLiteOrbit/Subscription/OrbitRegionSubscription.swift).

   Resolved 2026-10-08: widen every source to the union of its current and requested regions before
   narrowing any source. A failed widening preserves the previous coverage; a failed narrowing is
   harmless extra delivery and does not fail the update. The public callback contract now explicitly
   requires preserving previous coverage on error. Regression coverage exercises writer and
   transport failures during both phases, sibling and peer delivery, and later successful updates.

3. **The IPC wrapper drops its writer's active-writer barrier.** Give a custom public multiprocess
   writer a non-nil `captureActiveWriters()` result. `OrbitIPCDatabase` wrapping it returns nil,
   because it inherits the observable protocol's default implementation. Coalesced observations
   cannot use that underlying writer cohort through the wrapper. Existing built-in multiprocess
   drivers use serial writes; this matters for custom drivers supplying coordination. Forwarding
   the underlying snapshot would address that loss; coordination for commits from sibling handles
   is a separate policy question.

   Evidence: [IPC observable conformance](../Sources/SQLiteOrbit/IPC/OrbitIPCDatabase.swift),
   [default barrier implementation](../Sources/SQLiteOrbit/Observation/OrbitDatabaseTransactionObservation.swift).

   Resolved 2026-10-08: `OrbitIPCDatabase.captureActiveWriters()` forwards to its writer. The existing
   public custom-driver observation test now also runs through the IPC wrapper, verifying delayed
   refetches, finite writer cohorts, and refetching with no active writers.

4. **Section equality is a deliberate semantic choice worth revisiting.** Grouping `[1, 2, 1]`
   and `[1, 1, 2]` by identity produces equal section collections, although their public `elements`
   arrays differ. Equality compares sections and their rows, exactly as documented. Consequently,
   equality-based suppression observes grouped order, not every change to the original flat order.
   Decide whether equality should also include `elements`; this is not an undocumented violation
   of the current contract.

   Evidence: [section collection equality](../Sources/SQLiteOrbit/Fetching/OrbitFetchSectionCollection.swift).

   Decided 2026-10-08: retain the current equality to match SQLiteData. Its
   [ResultsSectionCollection](https://github.com/pointfreeco/sqlite-data/blob/main/Sources/SQLiteData/ResultsSectionCollection.swift)
   also uses `lhs.elementsEqual(rhs)`, comparing section names and rows rather than flat interleaving.

No additional confirmed library-owned "internal hell" blocker emerged. One optional extension
point remains: the public, documentation-hidden `_OrbitFetchSectioning` carrier exposes neither
its projection nor its ordering fragment. An external custom query helper cannot inspect those
separately. Current `FetchAll` already composes the public `sectionedRequest(by:)`, so it does not
require opening those members. If custom section-query builders are desired, consider a stable
section-expression value with public fragment access. Separately, sectioning depends on upstream
Structured Queries' underscored `_OrderingTerm`, `_OptionalProtocol`, and `_OptionalPromotable`;
that is dependency coupling rather than inaccessible APIs within SQLiteOrbit.

Evidence: [sectioning carrier](../Sources/SQLiteOrbit/Fetching/OrbitFetchSectioning.swift),
[public sectioned request composition](../Sources/SQLiteOrbit/SQL/OrbitSectionedRequest.swift).

Validation on Linux: the final default suite passed 774 tests; the minimal SystemSQLite suite
and the 72-test Turso compatibility/migration/timeout/scheduler subset also passed. The focused
run passed 124 tests including all four temporary reproductions. Swift formatting and diff checks
were clean. No Apple-platform or Windows runtime validation was performed in this review.

October 8 follow-up validation: all 775 default-suite tests passed, including the new subscription
failure cases and the existing writer-barrier test exercised through IPC. Formatting and diff
checks passed.
