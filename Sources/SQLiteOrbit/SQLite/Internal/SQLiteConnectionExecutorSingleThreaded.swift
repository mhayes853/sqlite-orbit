#if os(WASI) && !_runtime(_multithreaded)
  /// Runs connection jobs on the only runtime thread, draining jobs added by a running job in
  /// arrival order. A blocking access can run only while that drain is idle.
  final class SQLiteConnectionExecutor: SerialExecutor {
    private struct State {
      var pending: [UnownedJob] = []
      var isRunning = false
    }

    private let state = Lock(State())

    init(path: OrbitDatabasePath, idleTimeout: Duration? = nil) {
      _ = path
      _ = idleTimeout
    }

    func sync<Result>(_ body: () throws -> Result) rethrows -> Result {
      state.withLock { state in
        precondition(
          !state.isRunning,
          "A blocking database access cannot be nested inside another access on the same connection."
        )
        state.isRunning = true
      }
      defer { drain() }
      return try body()
    }

    func enqueue(_ job: UnownedJob) {
      let shouldDrain = state.withLock { state in
        state.pending.append(job)
        guard !state.isRunning else { return false }
        state.isRunning = true
        return true
      }
      if shouldDrain { drain() }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
      UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
      precondition(state.withLock { $0.isRunning }, "Expected the SQLite connection executor.")
    }

    private func drain() {
      while true {
        let next = state.withLock { state -> UnownedJob? in
          guard !state.pending.isEmpty else {
            state.isRunning = false
            return nil
          }
          return state.pending.removeFirst()
        }
        guard let next else { return }
        next.runSynchronously(on: asUnownedSerialExecutor())
      }
    }
  }
#endif
