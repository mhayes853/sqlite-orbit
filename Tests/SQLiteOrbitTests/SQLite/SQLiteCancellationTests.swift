#if BuiltInSQLite
  import Foundation
  import StructuredQueries
  import Testing

  @testable import SQLiteOrbit

  private final class CallCounter: Sendable {
    private let count = Lock(0)

    var value: Int { count.withLock { $0 } }

    func record() {
      count.withLock { $0 += 1 }
    }

    func wait(untilAtLeast target: Int) async {
      while value < target {
        await Task.yield()
      }
    }
  }

  private let endlessMarker = "RECURSIVE counter"

  private func observedLibrary(steps: CallCounter, interrupts: CallCounter) -> SQLiteLibrary {
    let base = builtInTestLibrary
    var library = base
    library.step = { statement in
      if let sql = base.sql(statement), String(cString: sql).contains(endlessMarker) {
        steps.record()
      }
      return base.step(statement)
    }
    library.interrupt = { connection in
      interrupts.record()
      base.interrupt(connection)
    }
    return library
  }

  private func endlessRead(on driver: SQLiteQueue) -> Task<[Int], any Error> {
    Task {
      try await driver.read { transaction in
        try transaction.fetchAll(
          #sql(
            """
            WITH RECURSIVE counter(x) AS (
              SELECT 1 UNION ALL SELECT x + 1 FROM counter WHERE x < 2000000000
            )
            SELECT count(*) FROM counter
            """,
            as: Int.self
          )
        )
      }
    }
  }

  @Test
  func cancellingAQueuedAccessLeavesTheRunningOneAlone() async throws {
    let steps = CallCounter()
    let interrupts = CallCounter()
    var configuration = SQLiteConfiguration.default
    configuration.library = observedLibrary(steps: steps, interrupts: interrupts)
    let driver = try SQLiteQueue(path: ":memory:", configuration: configuration)

    // This access is inside `sqlite3_step` and is never cancelled.
    let running = endlessRead(on: driver)
    // Only the endless query is counted, so this is the moment it starts running.
    await steps.wait(untilAtLeast: 1)

    // This one is stuck behind it on the connection's queue, and is cancelled while waiting.
    let queued = Task {
      try await driver.read { transaction in
        try transaction.fetchAll(#sql("SELECT 1", as: Int.self))
      }
    }
    for _ in 0..<5000 {
      await Task.yield()
    }
    queued.cancel()
    // Give a stray interrupt time to land before ruling one out.
    for _ in 0..<5000 {
      await Task.yield()
    }

    // The cancelled access never owned the connection, so it must not have interrupted the query
    // that did. Interrupting on its behalf would abort an access that was never cancelled.
    #expect(interrupts.value == 0)
    #expect(running.isCancelled == false)

    // Cancelling the access that does own the connection stops its query, and only then.
    running.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await running.value
    }
    #expect(interrupts.value == 1)

    // The queued access was never going to run; it reports its cancellation once its turn comes.
    await #expect(throws: CancellationError.self) {
      _ = try await queued.value
    }
  }

  @Test
  func cancellingTheRunningAccessStopsItsQuery() async throws {
    let steps = CallCounter()
    let interrupts = CallCounter()
    var configuration = SQLiteConfiguration.default
    configuration.library = observedLibrary(steps: steps, interrupts: interrupts)
    let driver = try SQLiteQueue(path: ":memory:", configuration: configuration)

    let running = endlessRead(on: driver)
    await steps.wait(untilAtLeast: 1)
    running.cancel()

    // A query aborted by SQLite reports `SQLITE_INTERRUPT`, which is a cancellation and not a
    // database failure.
    await #expect(throws: CancellationError.self) {
      _ = try await running.value
    }

    // The interrupted access left the connection usable, with no transaction still open.
    try await driver.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    let count = try await driver.read { transaction in
      try transaction.fetchAll(#sql("SELECT count(*) FROM items", as: Int.self))
    }
    #expect(count == [0])
  }

  @Test
  func cancellingBeforeAnAccessStartsRunsNoQuery() async throws {
    let driver = try SQLiteQueue(path: ":memory:")
    try await driver.write { transaction in
      try transaction.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    }
    let blockerEntered = Lock(false)
    let releaseBlocker = Lock(false)
    let blocker = Task {
      try await driver.read { _ in
        blockerEntered.withLock { $0 = true }
        while !releaseBlocker.withLock({ $0 }) {}
      }
    }
    try await waitUntil { blockerEntered.withLock { $0 } }

    let task = Task {
      try await driver.write { transaction in
        try transaction.execute("INSERT INTO items (id) VALUES (1)")
      }
    }
    task.cancel()
    releaseBlocker.withLock { $0 = true }
    try await blocker.value
    await #expect(throws: CancellationError.self) {
      try await task.value
    }

    // The cancelled write never ran.
    let rows = try await driver.read { transaction in
      try transaction.fetchAll(#sql("SELECT count(*) FROM items", as: Int.self))
    }
    #expect(rows == [0])
  }

  private final class DelayedInterruptProbe: Sendable {
    private struct State {
      var firstStepEntered = false
      var mayFinishFirstStep = false
      var firstQueryFinished = false
      var interruptEntered = false
      var mayDeliverInterrupt = false
      var secondAccessEntered = false
    }

    private let state = Lock(State())

    var firstStepEntered: Bool { state.withLock { $0.firstStepEntered } }
    var firstQueryFinished: Bool { state.withLock { $0.firstQueryFinished } }
    var interruptEntered: Bool { state.withLock { $0.interruptEntered } }
    var secondAccessEntered: Bool { state.withLock { $0.secondAccessEntered } }

    func enterFirstStep() {
      state.withLock { $0.firstStepEntered = true }
      while !state.withLock({ $0.mayFinishFirstStep }) {}
    }

    func finishFirstQuery() {
      state.withLock { $0.firstQueryFinished = true }
    }

    func releaseFirstStep() {
      state.withLock { $0.mayFinishFirstStep = true }
    }

    func delayInterrupt() {
      state.withLock { $0.interruptEntered = true }
      while !state.withLock({ $0.mayDeliverInterrupt }) {}
    }

    func deliverInterrupt() {
      state.withLock { $0.mayDeliverInterrupt = true }
    }

    func enterSecondAccess() {
      state.withLock { $0.secondAccessEntered = true }
    }
  }

  @Test
  func aDelayedCancellationCannotInterruptTheNextAccess() async throws {
    let probe = DelayedInterruptProbe()
    let base = builtInTestLibrary
    var library = base
    library.step = { statement in
      let sql = base.sql(statement).map(String.init(cString:)) ?? ""
      if sql.contains("first cancellation target") {
        probe.enterFirstStep()
        let code = base.step(statement)
        if code == SQLiteResultCode.done.rawValue {
          probe.finishFirstQuery()
        }
        return code
      }
      return base.step(statement)
    }
    library.interrupt = { connection in
      probe.delayInterrupt()
      base.interrupt(connection)
    }

    var configuration = SQLiteConfiguration.default
    configuration.library = library
    let driver = try SQLiteQueue(path: ":memory:", configuration: configuration)
    let first = Task {
      try await driver.read { transaction in
        try transaction.fetchAll(
          #sql("SELECT 1 -- first cancellation target", as: Int.self)
        )
      }
    }
    try await waitUntil { probe.firstStepEntered }

    // `cancel()` runs the cancellation handler synchronously, so use a dedicated thread while the
    // injected interrupt deliberately waits.
    Thread.detachNewThread { first.cancel() }
    try await waitUntil { probe.interruptEntered }

    let second = Task {
      try await driver.read { transaction in
        probe.enterSecondAccess()
        return try transaction.fetchAll(#sql("SELECT 2", as: Int.self))
      }
    }

    probe.releaseFirstStep()
    try await waitUntil { probe.firstQueryFinished }
    for _ in 0..<1_000 { await Task.yield() }

    // The first access cannot release the connection while its interrupt is still in flight.
    #expect(!probe.secondAccessEntered)
    probe.deliverInterrupt()
    _ = try? await first.value
    #expect(try await second.value == [2])
  }

  private final class OverlapTracker: Sendable {
    private let state = Lock((inFlight: 0, peak: 0))

    var peak: Int { state.withLock { $0.peak } }

    func enter() {
      state.withLock { state in
        state.inFlight += 1
        state.peak = max(state.peak, state.inFlight)
      }
    }

    func leave() {
      state.withLock { $0.inFlight -= 1 }
    }
  }

  @Test
  func accessesOnOneConnectionNeverOverlap() async throws {
    let driver = try SQLiteQueue(path: ":memory:")
    let overlap = OverlapTracker()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          try await driver.read { transaction in
            overlap.enter()
            defer { overlap.leave() }
            _ = try transaction.fetchAll(#sql("SELECT 1", as: Int.self))
          }
        }
      }
      try await group.waitForAll()
    }

    // One connection, one access at a time.
    #expect(overlap.peak == 1)
  }
#endif
