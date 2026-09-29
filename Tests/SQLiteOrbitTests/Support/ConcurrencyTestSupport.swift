import Dispatch
import Foundation

@testable import SQLiteOrbit

/// Thrown when something a test waits for does not happen in time.
struct TestTimeout: Error {}

/// An error a test throws on purpose, to see what becomes of it.
///
/// Two are equal when their names are, so a test that throws more than one can tell which came
/// back.
///
/// ```swift
/// await #expect(throws: TestError()) {
///   try await database.write { _ in throw TestError() }
/// }
/// ```
struct TestError: Error, Equatable, CustomStringConvertible {
  let name: String

  init(_ name: String = "test error") {
    self.name = name
  }

  var description: String { self.name }
}

/// Waits, polling every few milliseconds, until `condition` holds.
///
/// - Parameters:
///   - timeout: How long to wait before throwing ``TestTimeout``.
///   - condition: Checked on the caller's isolation.
func waitUntil(
  timeout: Duration = .seconds(10),
  isolation: isolated (any Actor)? = #isolation,
  _ condition: () -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !condition() {
    guard clock.now < deadline else { throw TestTimeout() }
    try await Task.sleep(for: .milliseconds(2))
  }
}

/// Counts something that happens on any thread or task, and waits for it to have happened often
/// enough.
///
/// ```swift
/// let steps = TestCounter()
/// configuration.library.statements.execution.step = { statement in
///   steps.increment()
///   return base.statements.execution.step(statement)
/// }
/// ...
/// try await steps.waitForCount(1)
/// ```
final class TestCounter: Sendable {
  private let count = Lock(0)

  init() {}

  /// How many times ``increment()`` has been called.
  var value: Int { self.count.withLock { $0 } }

  /// Counts one more.
  ///
  /// - Returns: The count, this one included.
  @discardableResult
  func increment() -> Int {
    self.count.withLock { count in
      count += 1
      return count
    }
  }

  /// Waits until the count is at least `count`.
  ///
  /// - Throws: ``TestTimeout`` once `timeout` passes first.
  func waitForCount(_ count: Int, timeout: Duration = .seconds(5)) async throws {
    try await waitUntil(timeout: timeout) { self.value >= count }
  }
}

/// Records values handed to it from any thread or task, in the order they arrive.
///
/// `append` has the shape of most callbacks, so it can be handed to one directly:
///
/// ```swift
/// let recorder = TestRecorder<OrbitIPCMessage>()
/// let subscription = try transport.subscribe(to: database, onMessage: recorder.append)
/// try await recorder.waitForCount(1)
/// #expect(recorder.values == [message])
/// ```
final class TestRecorder<Value: Sendable>: Sendable {
  private let recorded = Lock([Value]())

  init() {}

  /// Everything recorded so far, oldest first.
  var values: [Value] { self.recorded.withLock { $0 } }

  /// How many values have been recorded.
  var count: Int { self.recorded.withLock { $0.count } }

  /// The value recorded most recently.
  var last: Value? { self.recorded.withLock { $0.last } }

  func append(_ value: Value) {
    self.recorded.withLock { $0.append(value) }
  }

  /// Forgets everything recorded so far.
  func removeAll() {
    self.recorded.withLock { $0.removeAll() }
  }

  /// Waits until at least `count` values have been recorded.
  ///
  /// - Throws: ``TestTimeout`` once `timeout` passes first.
  func waitForCount(_ count: Int, timeout: Duration = .seconds(5)) async throws {
    try await waitUntil(timeout: timeout) { self.count >= count }
  }

  /// Waits until what has been recorded satisfies `condition`.
  ///
  /// - Throws: ``TestTimeout`` once `timeout` passes first.
  func waitUntilValues(
    timeout: Duration = .seconds(5),
    _ condition: ([Value]) -> Bool
  ) async throws {
    try await waitUntil(timeout: timeout) { condition(self.values) }
  }
}

/// Tracks how many callers are inside a region at once, and the most there ever were.
///
/// ```swift
/// let overlap = OverlapTracker()
/// try await concurrently(50) { _ in
///   try await driver.read { _ in overlap.track { ... } }
/// }
/// #expect(overlap.peak == 1)
/// ```
final class OverlapTracker: Sendable {
  private let state = Lock((inFlight: 0, peak: 0))

  init() {}

  /// The most callers that were ever inside at once.
  var peak: Int { self.state.withLock { $0.peak } }

  func enter() {
    self.state.withLock { state in
      state.inFlight += 1
      state.peak = max(state.peak, state.inFlight)
    }
  }

  func leave() {
    self.state.withLock { $0.inFlight -= 1 }
  }

  /// Runs `body` counted as inside.
  func track<Result>(_ body: () throws -> Result) rethrows -> Result {
    self.enter()
    defer { self.leave() }
    return try body()
  }
}

/// Runs `body` `count` times at once, each in a child task of its own, and waits for them all.
///
/// ```swift
/// let counts = try await concurrently(8) { index in
///   try await database.read { try $0.fetchCount(Item.all) }
/// }
/// ```
///
/// - Parameters:
///   - count: How many tasks to run.
///   - body: Receives the index of its task, from zero.
/// - Returns: What each task returned, in the order of their indices.
/// - Throws: The first error a task threw, once the rest have been cancelled.
func concurrently<Result: Sendable>(
  _ count: Int,
  _ body: @escaping @Sendable (_ index: Int) async throws -> Result
) async throws -> [Result] {
  try await withThrowingTaskGroup(of: (Int, Result).self) { group in
    for index in 0..<count {
      group.addTask { (index, try await body(index)) }
    }
    var results = [Result?](repeating: nil, count: count)
    for try await (index, result) in group {
      results[index] = result
    }
    return results.map { $0! }
  }
}

#if !os(WASI)
  /// A gate that whatever reaches it waits at, blocking its thread, until the test opens it.
  ///
  /// It holds a thread where a test needs something to stay inside a transaction or a callback
  /// while it looks at what everything else does, and lets it go on with ``open()``. It works the
  /// same whether what reaches it runs on a thread of its own, a connection's thread or a task.
  ///
  /// ```swift
  /// let gate = TestGate()
  /// let read = Task { try await pool.read { _ in try gate.enter() } }
  /// try await gate.waitUntilEntered()
  /// ... // The read is inside its transaction here.
  /// gate.open()
  /// try await read.value
  /// ```
  final class TestGate: Sendable {
    private struct State {
      var entered = 0
      var waiting = 0
      var isOpen = false
    }

    private let state = Lock(State())
    private let opened = DispatchSemaphore(value: 0)

    init() {}

    /// How many callers have reached the gate, whether they are still waiting or not.
    var enteredCount: Int { self.state.withLock { $0.entered } }

    /// Whether ``open()`` has been called.
    var isOpen: Bool { self.state.withLock { $0.isOpen } }

    /// Reaches the gate, and blocks the calling thread until it is open.
    ///
    /// - Parameter timeout: How long to wait for the gate to open, so that a test that fails
    ///   before opening it does not leave the thread held for good.
    /// - Throws: ``TestTimeout`` once `timeout` passes first.
    func enter(timeout: Duration = .seconds(30)) throws {
      let mustWait = self.state.withLock { state in
        state.entered += 1
        guard !state.isOpen else { return false }
        state.waiting += 1
        return true
      }
      guard mustWait else { return }
      if self.opened.blockingWait(timeout: .now(advancedBy: timeout)) == .timedOut {
        throw TestTimeout()
      }
    }

    /// Opens the gate, letting whatever is waiting at it go on, and whatever reaches it later
    /// pass straight through.
    func open() {
      let waiting = self.state.withLock { state in
        state.isOpen = true
        defer { state.waiting = 0 }
        return state.waiting
      }
      for _ in 0..<waiting { self.opened.signal() }
    }

    /// Waits until at least `count` callers have reached the gate.
    ///
    /// - Throws: ``TestTimeout`` once `timeout` passes first.
    func waitUntilEntered(_ count: Int = 1, timeout: Duration = .seconds(10)) async throws {
      try await waitUntil(timeout: timeout) { self.enteredCount >= count }
    }

    /// Waits, blocking the calling thread, until at least `count` callers have reached the gate.
    ///
    /// - Throws: ``TestTimeout`` once `timeout` passes first.
    func waitUntilEnteredBlocking(_ count: Int = 1, timeout: Duration = .seconds(10)) throws {
      let deadline = ContinuousClock.now.advanced(by: timeout)
      while self.enteredCount < count {
        guard ContinuousClock.now < deadline else { throw TestTimeout() }
        Thread.sleep(forTimeInterval: 0.001)
      }
    }
  }

  extension DispatchTime {
    /// The time `duration` from now.
    static func now(advancedBy duration: Duration) -> DispatchTime {
      let (seconds, attoseconds) = duration.components
      return .now() + .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
  }

  /// Runs `body` `count` times at once, each on a thread of its own, and waits at most `timeout`
  /// for them all.
  ///
  /// No thread runs `body` until every one of them has started, so they reach it together rather
  /// than one after another as they are spawned. A thread that never returns is left behind.
  ///
  /// ```swift
  /// try await concurrentlyOnThreads(8) { _ in
  ///   try pool.writeBlocking { try $0.execute("UPDATE counter SET n = n + 1") }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - count: How many threads to run.
  ///   - timeout: How long to wait for every thread to return.
  ///   - body: Receives the index of its thread, from zero.
  /// - Returns: What each thread returned, in the order of their indices.
  /// - Throws: ``TestTimeout`` once `timeout` passes first, or else the error of the first thread,
  ///   by index, that threw.
  func concurrentlyOnThreads<Result: Sendable>(
    _ count: Int,
    timeout: Duration = .seconds(30),
    _ body: @escaping @Sendable (_ index: Int) throws -> Result
  ) async throws -> [Result] {
    let start = TestGate()
    let outcomes = Lock([Int: Swift.Result<Result, any Error>]())
    for index in 0..<count {
      Thread.detachNewThread {
        let outcome = Swift.Result { () throws -> Result in
          try start.enter(timeout: timeout)
          return try body(index)
        }
        outcomes.withLock { $0[index] = outcome }
      }
    }
    try await start.waitUntilEntered(count, timeout: timeout)
    start.open()
    try await waitUntil(timeout: timeout) { outcomes.withLock { $0.count } == count }
    return try outcomes.withLock { outcomes in
      try (0..<count).map { try outcomes[$0]!.get() }
    }
  }

  /// Runs `body` on a thread of its own, and waits at most `timeout` for it to return.
  ///
  /// Whatever might block runs this way, so a change that makes it wait on a stalled process fails
  /// the test with a ``TestTimeout`` rather than hanging it. The thread is left behind if it never
  /// returns.
  func withDeadline<Value: Sendable>(
    _ timeout: Duration = .seconds(10),
    _ body: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    let outcome = Lock<Result<Value, any Error>?>(nil)
    Thread.detachNewThread {
      let result = Result { try body() }
      outcome.withLock { $0 = result }
    }
    try await waitUntil(timeout: timeout) { outcome.withLock { $0 != nil } }
    return try outcome.withLock { $0! }.get()
  }

  /// Holds a lock on a thread of its own, from when it is made until it is released.
  final class LockHolder: Sendable {
    private let acquired = DispatchSemaphore(value: 0)
    private let mayRelease = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// Returns once `withLock` is holding its lock.
    ///
    /// - Parameter withLock: Takes the lock, and runs the closure it is handed while holding it.
    init(_ withLock: @escaping @Sendable (_ whileHeld: () -> Void) throws -> Void) {
      Thread.detachNewThread {
        try? withLock {
          self.acquired.signal()
          self.mayRelease.blockingWait()
        }
        self.released.signal()
      }
      self.acquired.blockingWait()
    }

    /// Lets go of the lock, and returns once it has.
    func release() {
      self.mayRelease.signal()
      self.released.blockingWait()
    }
  }
#endif
