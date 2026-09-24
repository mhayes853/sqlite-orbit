// Darwin keeps libdispatch, which is part of the system there and which the scheduler understands:
// a queue's QoS raises the thread that drains it. Windows keeps it too for now, until it has a
// backend of its own over Win32's locks and condition variables, which belongs in a branch of its
// own between this one and the pthread one. Everywhere else libdispatch is a library the package
// would drag along for a lock and a thread, so those platforms get exactly that from pthreads.
#if canImport(Darwin) || os(Windows)
  import Dispatch

  final class SQLiteConnectionExecutor: SerialExecutor {
    private let queue: DispatchQueue

    private static let owner = DispatchSpecificKey<ObjectIdentifier>()

    init(path: OrbitDatabasePath) {
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
        """
        A blocking database access cannot be nested inside another one on the same connection: \
        the inner access would wait for the outer one to release a connection it still holds. \
        Use the transaction already in hand rather than opening a second one.
        """
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
  /// The executor has one runner at a time: the thread its asynchronous jobs run on, or a thread
  /// running a blocking access. A blocking access runs on the thread that asked for it, as
  /// libdispatch runs `sync` on an idle queue, so it costs no thread hop. Jobs run on a worker
  /// thread that is started for the first job and ends after sitting idle, so an idle connection
  /// holds no thread. Jobs and blocking accesses wait their turn in one queue, in the order they
  /// arrived.
  final class SQLiteConnectionExecutor: SerialExecutor {
    let state: State

    init(path: OrbitDatabasePath, idleTimeout: Duration = .seconds(5)) {
      self.state = State(threadName: Self.threadName(for: path), idleTimeout: idleTimeout)
    }

    // An idle worker would otherwise sit out the rest of its timeout for a connection nothing can
    // reach any more.
    deinit {
      state.close()
    }

    func sync<Result>(_ body: () throws -> Result) rethrows -> Result {
      state.acquire(on: .current)
      defer { state.release() }
      return try body()
    }

    // A job's priority is dropped, and jobs run in the order they arrived. On Linux libdispatch's
    // QoS does not raise the priority of the thread running a block the way it does on Darwin, so
    // honoring it here would buy reordering and nothing the scheduler acts on.
    //
    // This is the entry point every platform has. Implementing the newer one as well would mean
    // implementing neither: a type that has this one is never asked for the other.
    func enqueue(_ job: UnownedJob) {
      state.enqueue(job, on: self)
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
      UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
      precondition(
        state.isRunner(.current),
        "Expected to be running on the executor of the SQLite connection \(state.threadName)."
      )
    }

    // A worker is named for the database it serves, because a stack of blocked threads is most of
    // what a hang report of this package will show. A database private to its connection has no
    // name worth showing, and a file's directory would not fit in the length Linux allows.
    private static func threadName(for path: OrbitDatabasePath) -> String {
      switch path {
      case .memory: "Orbit :memory:"
      case .temporary: "Orbit temporary"
      default: "Orbit \(path.sqlitePath.split(separator: "/").last ?? "")"
      }
    }
  }

  extension SQLiteConnectionExecutor {
    /// What the executor and its worker share, which is all the worker holds on to, so an idle
    /// worker never keeps the executor alive.
    ///
    /// Everything mutable is guarded by `lock`, and only the worker waits on its condition.
    final class State: @unchecked Sendable {
      let threadName: String
      private let idleTimeout: Duration
      private let lock = ConditionLock()

      private var pending = PendingQueue()
      private var runner: ThreadID?
      private var hasWorker = false
      private var isWorkerWaiting = false
      private var isClosed = false
      private var workersStarted = 0

      init(threadName: String, idleTimeout: Duration) {
        self.threadName = threadName
        self.idleTimeout = idleTimeout
      }

      // Called by `sync` to make the calling thread the runner, waiting its turn when the executor
      // is busy.
      func acquire(on thread: ThreadID) {
        lock.lock()
        precondition(
          runner != thread,
          """
          A blocking database access cannot be nested inside another one on the same connection: \
          the inner access would wait for the outer one to release a connection it still holds. \
          Use the transaction already in hand rather than opening a second one.
          """
        )
        if runner == nil && pending.isEmpty {
          runner = thread
          lock.unlock()
          return
        }
        // Queued behind whatever arrived first, so a blocking access is neither starved by a
        // stream of jobs nor served ahead of the jobs that were waiting before it.
        let ticket = SyncTicket(thread: thread)
        pending.append(.sync(ticket))
        lock.unlock()
        ticket.waitUntilGranted()
      }

      // Called by `sync` once its body returns, to hand the executor to whatever waits next.
      func release() {
        lock.lock()
        runner = nil
        let handoff = dispatchNext()
        lock.unlock()
        handoff.perform(with: self)
      }

      func enqueue(_ job: UnownedJob, on executor: SQLiteConnectionExecutor) {
        lock.lock()
        // The executor is retained until the job has run, as the block libdispatch would have run
        // it in retains it, so that a job dropping the last reference to its actor cannot free the
        // executor while the job is still running on it.
        pending.append(.job(job, Unmanaged.passRetained(executor)))
        let handoff = runner == nil ? dispatchNext() : .none
        lock.unlock()
        handoff.perform(with: self)
      }

      func close() {
        lock.withLock {
          isClosed = true
          if isWorkerWaiting { lock.signal() }
        }
      }

      func isRunner(_ thread: ThreadID) -> Bool {
        lock.withLock { runner == thread }
      }

      // Decides who runs next once the executor has no runner. Must be called holding `lock`.
      //
      // A blocking access at the head of the queue is made the runner here and now, so it never
      // waits on the worker to wake up. A job is left for the worker, which is woken, or started
      // if there is none. That the worker's decision to end is made under the same lock is what
      // keeps a job from being queued just as its worker leaves.
      private func dispatchNext() -> Handoff {
        switch pending.first {
        case nil:
          return .none
        case .sync(let ticket):
          pending.removeFirst()
          runner = ticket.thread
          return .grant(ticket)
        case .job:
          if hasWorker {
            if isWorkerWaiting { lock.signal() }
            return .none
          }
          hasWorker = true
          workersStarted += 1
          return .startWorker
        }
      }

      private func runWorker() {
        let worker = ThreadID.current
        lock.lock()
        while true {
          if runner == nil, let entry = pending.removeFirst() {
            switch entry {
            case .job(let job, let executor):
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
            case .sync(let ticket):
              runner = ticket.thread
              lock.unlock()
              ticket.grant()
              lock.lock()
            }
            continue
          }

          // Nothing here can run now: the queue is empty, or a blocking access holds the executor
          // and will hand it back through `release`. A closed executor has nothing left to queue.
          if isClosed {
            break
          }
          isWorkerWaiting = true
          let wasSignalled = lock.wait(timeout: idleTimeout)
          isWorkerWaiting = false
          if !wasSignalled && (runner != nil || pending.isEmpty) {
            break
          }
        }
        hasWorker = false
        lock.unlock()
      }

      fileprivate func startWorker() {
        DetachedThread.spawn(name: threadName) { [self] in runWorker() }
      }
    }
  }

  // Introspection for tests.
  extension SQLiteConnectionExecutor.State {
    var hasRunningWorker: Bool {
      lock.withLock { hasWorker }
    }

    var startedWorkerCount: Int {
      lock.withLock { workersStarted }
    }

    var pendingCount: Int {
      lock.withLock { pending.count }
    }
  }

  // What a thread leaving the executor must do once it has let go of the lock: waking a blocking
  // access or starting a thread under it would only hold up everyone else waiting on it.
  private enum Handoff {
    case none
    case grant(SyncTicket)
    case startWorker

    func perform(with state: SQLiteConnectionExecutor.State) {
      switch self {
      case .none: break
      case .grant(let ticket): ticket.grant()
      case .startWorker: state.startWorker()
      }
    }
  }

  // A blocking access waiting its turn in the queue.
  //
  // Each one waits on a condition of its own, so handing the executor to one wakes that one
  // alone, rather than every thread waiting on the connection.
  private final class SyncTicket: @unchecked Sendable {
    let thread: ThreadID
    private let lock = ConditionLock()
    private var isGranted = false

    init(thread: ThreadID) {
      self.thread = thread
    }

    func waitUntilGranted() {
      lock.lock()
      while !isGranted { lock.wait() }
      lock.unlock()
    }

    func grant() {
      lock.withLock {
        isGranted = true
        lock.signal()
      }
    }
  }

  private enum PendingEntry {
    case job(UnownedJob, Unmanaged<SQLiteConnectionExecutor>)
    case sync(SyncTicket)
  }

  // A first-in, first-out queue that does not shift every entry forward to remove the first one.
  private struct PendingQueue {
    private var entries: [PendingEntry?] = []
    private var head = 0

    var isEmpty: Bool { head == entries.count }
    var count: Int { entries.count - head }
    var first: PendingEntry? { isEmpty ? nil : entries[head] }

    mutating func append(_ entry: PendingEntry) {
      entries.append(entry)
    }

    @discardableResult
    mutating func removeFirst() -> PendingEntry? {
      guard !isEmpty else { return nil }
      let entry = entries[head]
      entries[head] = nil
      head += 1
      // The consumed prefix is dropped once it outweighs what is left, which keeps removal
      // amortized constant without the array growing for as long as the queue is never empty.
      if head == entries.count {
        entries.removeAll(keepingCapacity: true)
        head = 0
      } else if head >= 32 && head * 2 >= entries.count {
        entries.removeFirst(head)
        head = 0
      }
      return entry
    }
  }
#else
  #error(
    "SQLiteOrbit requires a multithreaded runtime: a connection runs its work on a thread of its own and blocks callers while it does. On WebAssembly, build for wasm32-unknown-wasip1-threads."
  )
#endif
