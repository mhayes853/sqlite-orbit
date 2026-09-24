// Darwin keeps libdispatch, whose QoS the scheduler there acts on. Windows keeps it until it has a
// Win32 backend of its own. Everywhere else a mutex and a thread of the executor's own replace it.
#if canImport(Darwin) || os(Windows)
  import Dispatch
#endif

#if !_runtime(_multithreaded)
  #error(
    "SQLiteOrbit requires a multithreaded runtime: a connection runs its work on a thread of its own and blocks callers while it does. On WebAssembly, build for wasm32-unknown-wasip1-threads."
  )
#endif

private let nestedBlockingAccessMessage = """
  A blocking database access cannot be nested inside another one on the same connection: \
  the inner access would wait for the outer one to release a connection it still holds. \
  Use the transaction already in hand rather than opening a second one.
  """

/// Serializes a connection's jobs and its blocking accesses.
///
/// Outside Darwin and Windows one thread runs at a time. A blocking access runs inline on the
/// thread that asked for it, as libdispatch runs `sync` on an idle queue. Jobs run on a worker
/// thread that is started for the first job and ends after sitting idle, so an idle connection
/// holds no thread. Both wait their turn in one queue, in the order they arrived.
final class SQLiteConnectionExecutor: SerialExecutor {
  #if canImport(Darwin) || os(Windows)
    private let queue: DispatchQueue

    private static let owner = DispatchSpecificKey<ObjectIdentifier>()
  #else
    let state: ConditionLock<State>
    private let threadName: String
    private let idleTimeout: Duration
  #endif

  // The idle timeout is the pthread executor's; libdispatch manages its own threads.
  init(path: OrbitDatabasePath, idleTimeout: Duration? = nil) {
    #if canImport(Darwin) || os(Windows)
      // The queue is labelled with the database it serves, because a stack of blocked threads is
      // most of what a hang report of this package will show.
      self.queue = DispatchQueue(
        label: "SQLiteOrbit.connection(\(path))",
        autoreleaseFrequency: .workItem
      )
      queue.setSpecific(key: Self.owner, value: ObjectIdentifier(self))
    #else
      self.state = ConditionLock(State())
      self.threadName = Self.threadName(for: path)
      self.idleTimeout = idleTimeout ?? .seconds(5)
    #endif
  }

  #if !canImport(Darwin) && !os(Windows)
    // An idle worker would otherwise sit out the rest of its timeout for a connection nothing can
    // reach any more.
    deinit {
      state.withLock { $0.isClosed = true }
    }
  #endif

  func sync<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(Darwin) || os(Windows)
      precondition(
        DispatchQueue.getSpecific(key: Self.owner) != ObjectIdentifier(self),
        nestedBlockingAccessMessage
      )
      return try queue.sync(execute: body)
    #else
      // Queuing behind whatever arrived first means a blocking access is neither starved by a
      // stream of jobs nor served ahead of the jobs that were waiting before it.
      let thread = ThreadID.current
      let isQueued = state.withLock { state in
        precondition(state.runner != thread, nestedBlockingAccessMessage)
        guard state.runner != nil || !state.pending.isEmpty else {
          state.runner = thread
          return false
        }
        state.pending.append(.sync(thread))
        return true
      }
      if isQueued {
        let isThisTurn = { (state: borrowing State) in
          state.runner == nil && state.isSyncAtHead(thread)
        }
        state.withLock(until: isThisTurn) { state, _ in
          state.pending.removeFirst()
          state.runner = thread
        }
      }
      defer {
        let startsWorker = state.withLock { state in
          state.runner = nil
          return state.claimWorkerStart()
        }
        if startsWorker { startWorker() }
      }
      return try body()
    #endif
  }

  // This is the entry point every platform has. Implementing the newer one as well would mean
  // implementing neither: a type that has this one is never asked for the other.
  func enqueue(_ job: UnownedJob) {
    #if canImport(Darwin) || os(Windows)
      // A job's priority is handed to dispatch rather than dropped. Without it every query would
      // run at the queue's own QoS, so a read a user is waiting on would be served no sooner than a
      // background one, and the thread running it would not be raised to match. Dispatch also
      // resolves the inversion this leaves behind: a high-priority block enqueued behind a
      // low-priority one raises the queue until it drains.
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else {
        return run(job, at: .unspecified)
      }
      run(job, at: Self.dispatchQoS(for: job.priority))
    #else
      // A job's priority is dropped, and jobs run in the order they arrived. On Linux libdispatch's
      // QoS does not raise the priority of the thread running a block the way it does on Darwin,
      // so honoring it here would buy reordering and nothing the scheduler acts on.
      //
      // The executor is retained until the job has run, as the block libdispatch would have run it
      // in retains it, so that a job dropping the last reference to its actor cannot free the
      // executor while the job is still running on it.
      let startsWorker = state.withLock { state in
        state.pending.append(.job(job, Unmanaged.passRetained(self)))
        return state.claimWorkerStart()
      }
      if startsWorker { startWorker() }
    #endif
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }

  func checkIsolated() {
    #if canImport(Darwin) || os(Windows)
      dispatchPrecondition(condition: .onQueue(queue))
    #else
      let thread = ThreadID.current
      precondition(
        state.withLock { $0.runner == thread },
        "Expected to be running on the executor of the SQLite connection \(threadName)."
      )
    #endif
  }

  #if canImport(Darwin) || os(Windows)
    private func run(_ job: UnownedJob, at qos: DispatchQoS) {
      queue.async(qos: qos) {
        job.runSynchronously(on: self.asUnownedSerialExecutor())
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private static func dispatchQoS(for priority: JobPriority) -> DispatchQoS {
      guard let priority = TaskPriority(priority) else { return .unspecified }
      if priority >= .high { return .userInitiated }
      if priority >= .medium { return .default }
      if priority >= .low { return .utility }
      return .background
    }
  #else
    // The worker holds the state, never the executor, so an idle worker never keeps it alive.
    private func startWorker() {
      let state = state
      let idleTimeout = idleTimeout
      DetachedThread.spawn(name: threadName) {
        Self.runWorker(state: state, idleTimeout: idleTimeout)
      }
    }

    private static func runWorker(state: ConditionLock<State>, idleTimeout: Duration) {
      let worker = ThreadID.current
      let hasJobToRun = { (state: borrowing State) in
        state.isClosed || (state.runner == nil && state.isJobAtHead)
      }
      while true {
        // A worker that finds nothing to run for `idleTimeout` ends, and says so under the same
        // lock the next job is queued under, so that job starts another rather than waiting on
        // this one.
        let next = state.withLock(until: hasJobToRun, timeout: idleTimeout) {
          (state, isReady) -> State.Entry? in
          guard isReady && !state.isClosed else {
            state.hasWorker = false
            return nil
          }
          state.runner = worker
          return state.pending.removeFirst()
        }
        guard case .job(let job, let executor)? = next else { return }
        job.runSynchronously(on: UnownedSerialExecutor(ordinary: executor.takeUnretainedValue()))
        // Released before the lock is taken back, because this may be the last reference, and the
        // executor's deinit takes the lock too.
        executor.release()
        state.withLock { $0.runner = nil }
      }
    }

    // A worker is named for the database it serves, because a stack of blocked threads is most of
    // what a hang report of this package will show. Linux and Android keep only 15 bytes of a
    // name, so it is cut short here, where a character can be kept whole.
    private static func threadName(for path: OrbitDatabasePath) -> String {
      let name: String
      switch path {
      case .memory: name = "Orbit :memory:"
      case .temporary: name = "Orbit temporary"
      default:
        let path = path.sqlitePath
        let file = path.lastIndex(of: "/").map { path[path.index(after: $0)...] } ?? path[...]
        name = "Orbit \(file)"
      }
      var length = 0
      for index in name.unicodeScalars.indices {
        length += UTF8.width(name.unicodeScalars[index])
        if length > 15 { return String(name.unicodeScalars[..<index]) }
      }
      return name
    }
  #endif
}

#if os(Windows)
  extension SQLiteConnectionExecutor: @unchecked Sendable {}
#endif

#if !canImport(Darwin) && !os(Windows)
  extension SQLiteConnectionExecutor {
    struct State {
      enum Entry {
        case job(UnownedJob, Unmanaged<SQLiteConnectionExecutor>)
        case sync(ThreadID)
      }

      var pending = [Entry]()
      var runner: ThreadID?
      var hasWorker = false
      var isClosed = false

      var isJobAtHead: Bool {
        if case .job? = pending.first { true } else { false }
      }

      func isSyncAtHead(_ thread: ThreadID) -> Bool {
        if case .sync(let head)? = pending.first { head == thread } else { false }
      }

      // Whether a worker must be started for a job at the head of the queue, which is then
      // recorded as started. Only the worker runs jobs, and only one worker runs at a time.
      mutating func claimWorkerStart() -> Bool {
        guard isJobAtHead && !hasWorker else { return false }
        hasWorker = true
        return true
      }
    }
  }
#endif
