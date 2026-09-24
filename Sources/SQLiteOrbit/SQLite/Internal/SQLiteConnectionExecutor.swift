// Darwin keeps libdispatch, whose QoS the scheduler there acts on. Windows keeps it until it has a
// Win32 backend of its own, which would go in a branch between these two. Everywhere else a mutex
// and a thread of the executor's own replace it.

private let nestedBlockingAccessMessage = """
  A blocking database access cannot be nested inside another one on the same connection: \
  the inner access would wait for the outer one to release a connection it still holds. \
  Use the transaction already in hand rather than opening a second one.
  """

#if canImport(Darwin) || os(Windows)
  import Dispatch

  final class SQLiteConnectionExecutor: SerialExecutor {
    private let queue: DispatchQueue

    private static let owner = DispatchSpecificKey<ObjectIdentifier>()

    // The idle timeout is the pthread executor's; libdispatch manages its own threads.
    init(path: OrbitDatabasePath, idleTimeout: Duration? = nil) {
      // The queue is labelled with the database it serves, because a stack of blocked threads is
      // most of what a hang report of this package will show.
      self.queue = DispatchQueue(
        label: "SQLiteOrbit.connection(\(path))",
        autoreleaseFrequency: .workItem
      )
      queue.setSpecific(key: Self.owner, value: ObjectIdentifier(self))
    }

    func sync<Result>(_ body: () throws -> Result) rethrows -> Result {
      precondition(
        DispatchQueue.getSpecific(key: Self.owner) != ObjectIdentifier(self),
        nestedBlockingAccessMessage
      )
      return try queue.sync(execute: body)
    }

    // A job's priority is handed to dispatch rather than dropped. Without it every query would run
    // at the queue's own QoS, so a read a user is waiting on would be served no sooner than a
    // background one, and the thread running it would not be raised to match. Dispatch also
    // resolves the inversion this leaves behind: a high-priority block enqueued behind a
    // low-priority one raises the queue until it drains.
    //
    // This is the entry point every platform has. Implementing the newer one as well would mean
    // implementing neither: a type that has this one is never asked for the other.
    func enqueue(_ job: UnownedJob) {
      guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else {
        return run(job, at: .unspecified)
      }
      run(job, at: Self.dispatchQoS(for: job.priority))
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
      UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
      dispatchPrecondition(condition: .onQueue(queue))
    }

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
  }

  #if os(Windows)
    extension SQLiteConnectionExecutor: @unchecked Sendable {}
  #endif
#elseif _runtime(_multithreaded)
  /// Serializes a connection's jobs and blocking accesses over a mutex and a thread of its own.
  ///
  /// One thread runs at a time. A blocking access runs inline on the thread that asked for it, as
  /// libdispatch runs `sync` on an idle queue. Jobs run on a worker thread that is started for the
  /// first job and ends after sitting idle, so an idle connection holds no thread. Both wait their
  /// turn in one queue, in the order they arrived.
  final class SQLiteConnectionExecutor: SerialExecutor {
    let state: State

    init(path: OrbitDatabasePath, idleTimeout: Duration? = nil) {
      self.state = State(
        threadName: Self.threadName(for: path),
        idleTimeout: idleTimeout ?? .seconds(5)
      )
    }

    // An idle worker would otherwise sit out the rest of its timeout for a connection nothing can
    // reach any more.
    deinit {
      state.close()
    }

    func sync<Result>(_ body: () throws -> Result) rethrows -> Result {
      state.acquire()
      defer { state.release() }
      return try body()
    }

    // A job's priority is dropped, and jobs run in the order they arrived. On Linux libdispatch's
    // QoS does not raise the priority of the thread running a block the way it does on Darwin, so
    // honoring it here would buy reordering and nothing the scheduler acts on.
    //
    // Like the libdispatch executor's, this is the entry point every platform has.
    func enqueue(_ job: UnownedJob) {
      state.enqueue(job, on: self)
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
      UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
      precondition(
        state.isRunningOnCurrentThread,
        "Expected to be running on the executor of the SQLite connection \(state.threadName)."
      )
    }

    // A worker is named for the database it serves, because a stack of blocked threads is most of
    // what a hang report of this package will show. Linux and Android refuse a name longer than 15
    // bytes, so it is cut short here, where a character can be kept whole.
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
  }

  extension SQLiteConnectionExecutor {
    /// What the executor and its worker share, which is all the worker holds on to, so an idle
    /// worker never keeps the executor alive.
    ///
    /// Everything mutable is guarded by `lock`. Blocking accesses and the worker all wait on its
    /// one condition, and every hand-off wakes them all: a connection has only a few waiters.
    final class State: @unchecked Sendable {
      let threadName: String
      private let idleTimeout: Duration
      private let lock = ConditionLock()

      private var pending = [PendingEntry]()
      private var runner: ThreadID?
      private var hasWorker = false
      private var isClosed = false

      init(threadName: String, idleTimeout: Duration) {
        self.threadName = threadName
        self.idleTimeout = idleTimeout
      }

      // Called by `sync` to make the calling thread the runner, waiting its turn when the executor
      // is busy. Queuing behind whatever arrived first means a blocking access is neither starved
      // by a stream of jobs nor served ahead of the jobs that were waiting before it.
      func acquire() {
        let thread = ThreadID.current
        lock.lock()
        defer { lock.unlock() }
        precondition(runner != thread, nestedBlockingAccessMessage)
        if runner == nil && pending.isEmpty {
          runner = thread
          return
        }
        pending.append(.sync(thread))
        while runner != thread { lock.wait() }
      }

      func release() {
        lock.lock()
        runner = nil
        let startsWorker = handOff()
        lock.unlock()
        if startsWorker { startWorker() }
      }

      func enqueue(_ job: UnownedJob, on executor: SQLiteConnectionExecutor) {
        lock.lock()
        // The executor is retained until the job has run, as the block libdispatch would have run
        // it in retains it, so that a job dropping the last reference to its actor cannot free the
        // executor while the job is still running on it.
        pending.append(.job(job, Unmanaged.passRetained(executor)))
        let startsWorker = runner == nil && handOff()
        lock.unlock()
        if startsWorker { startWorker() }
      }

      func close() {
        lock.withLock {
          isClosed = true
          lock.broadcast()
        }
      }

      var isRunningOnCurrentThread: Bool {
        let thread = ThreadID.current
        return lock.withLock { runner == thread }
      }

      // Passes the idle executor to the head of the queue, holding `lock`. A blocking access is
      // made the runner at once; a job is left to the worker, and the caller is told to start one
      // once it has let go of the lock when there is none.
      private func handOff() -> Bool {
        switch pending.first {
        case nil:
          return false
        case .sync(let thread):
          pending.removeFirst()
          runner = thread
          lock.broadcast()
          return false
        case .job:
          if hasWorker {
            lock.broadcast()
            return false
          }
          hasWorker = true
          return true
        }
      }

      private func runWorker() {
        let worker = ThreadID.current
        lock.lock()
        while true {
          if runner == nil, case .job(let job, let executor)? = pending.first {
            pending.removeFirst()
            runner = worker
            lock.unlock()
            job.runSynchronously(
              on: UnownedSerialExecutor(ordinary: executor.takeUnretainedValue())
            )
            // Released before the lock is taken back, because this may be the last reference,
            // and the executor's deinit takes the lock too.
            executor.release()
            lock.lock()
            runner = nil
            _ = handOff()
            continue
          }
          // Nothing here can run: the queue is empty, or a blocking access holds the executor and
          // will hand it back through `release`, starting a worker if this one has gone. Ending
          // under the lock is what keeps a job from being queued just as its worker leaves.
          if isClosed { break }
          let wasWoken = lock.wait(timeout: idleTimeout)
          if !wasWoken && (runner != nil || pending.isEmpty) { break }
        }
        hasWorker = false
        lock.unlock()
      }

      private func startWorker() {
        DetachedThread.spawn(name: threadName) { [self] in runWorker() }
      }
    }
  }

  // Introspection for tests.
  extension SQLiteConnectionExecutor.State {
    var hasRunningWorker: Bool {
      lock.withLock { hasWorker }
    }

    var pendingCount: Int {
      lock.withLock { pending.count }
    }
  }

  private enum PendingEntry {
    case job(UnownedJob, Unmanaged<SQLiteConnectionExecutor>)
    case sync(ThreadID)
  }
#else
  #error(
    "SQLiteOrbit requires a multithreaded runtime: a connection runs its work on a thread of its own and blocks callers while it does. On WebAssembly, build for wasm32-unknown-wasip1-threads."
  )
#endif
