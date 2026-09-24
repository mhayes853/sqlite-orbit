// Only the pthread executor waits on a condition, so this is built only where that executor is.
// Darwin and Windows keep libdispatch, and a runtime without threads has nothing to wait for.
#if !canImport(Darwin) && !os(Windows) && _runtime(_multithreaded)
  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Android)
    import Android
  #elseif canImport(WASILibc)
    import WASILibc
  #endif

  /// A value guarded by a pthread mutex, with a condition to wait on until the value is ready.
  ///
  /// `Lock` cannot stand in for this: a `Synchronization.Mutex` has no condition variable to pair
  /// with. Staying on raw pthreads also keeps the thread sanitizer useful, because on Linux it
  /// models a pthread mutex as ordering the accesses made under it and a `Synchronization.Mutex`
  /// as ordering nothing.
  ///
  /// Every access wakes every waiter as it lets go of the lock, so no caller has to know who might
  /// be waiting on what it changed. Waiters test their own predicates again, and waking nobody is
  /// cheap.
  final class ConditionLock<Value> {
    // Both are allocated rather than stored inline because a pthread object must not move once it
    // is initialized, and nothing about a Swift property promises it an address that holds still.
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private let condition: UnsafeMutablePointer<pthread_cond_t>
    private var value: Value

    init(_ value: sending Value) {
      self.value = value
      self.mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
      self.mutex.initialize(to: pthread_mutex_t())
      self.condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
      self.condition.initialize(to: pthread_cond_t())
      precondition(pthread_mutex_init(mutex, nil) == 0, "pthread_mutex_init failed")

      #if os(WASI)
        // wasi-libc spells its clock ids as the addresses of C globals, which Swift cannot import,
        // so the condition keeps its default wall clock. Setting the clock can then end a timed
        // wait early or late, which the idle timeout this serves can afford.
        precondition(pthread_cond_init(condition, nil) == 0, "pthread_cond_init failed")
      #else
        // A timed wait measures against the monotonic clock, so setting the wall clock neither
        // cuts a wait short nor stretches it out.
        var attributes = pthread_condattr_t()
        precondition(pthread_condattr_init(&attributes) == 0, "pthread_condattr_init failed")
        defer { _ = pthread_condattr_destroy(&attributes) }
        precondition(
          pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC) == 0,
          "pthread_condattr_setclock failed"
        )
        precondition(pthread_cond_init(condition, &attributes) == 0, "pthread_cond_init failed")
      #endif
    }

    deinit {
      _ = pthread_cond_destroy(condition)
      condition.deinitialize(count: 1)
      condition.deallocate()
      _ = pthread_mutex_destroy(mutex)
      mutex.deinitialize(count: 1)
      mutex.deallocate()
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
      lock()
      defer { unlock() }
      return try body(&value)
    }

    /// Waits until `ready` holds, or until `timeout` has passed, then runs `body` under the lock.
    ///
    /// - Parameters:
    ///   - ready: Whether the value is what the caller is waiting for. It is tested under the lock,
    ///     first on entry and then each time another access lets go of it.
    ///   - timeout: How long to wait for `ready` to hold, or `nil` to wait for as long as it takes.
    ///   - body: Receives the value and whether `ready` held, which is `false` only once `timeout`
    ///     has passed.
    /// - Returns: Whatever `body` returned.
    func withLock<Result>(
      until ready: (borrowing Value) -> Bool,
      timeout: Duration? = nil,
      _ body: (inout Value, _ isReady: Bool) throws -> Result
    ) rethrows -> Result {
      lock()
      defer { unlock() }
      var deadline = timeout.map(Self.deadline(after:))
      while !ready(value) {
        if deadline == nil {
          let result = pthread_cond_wait(condition, mutex)
          precondition(result == 0, "pthread_cond_wait failed with \(result)")
        } else {
          let result = pthread_cond_timedwait(condition, mutex, &deadline!)
          precondition(
            result == 0 || result == ETIMEDOUT,
            "pthread_cond_timedwait failed with \(result)"
          )
          if result == ETIMEDOUT { return try body(&value, ready(value)) }
        }
      }
      return try body(&value, true)
    }

    private func lock() {
      let result = pthread_mutex_lock(mutex)
      precondition(result == 0, "pthread_mutex_lock failed with \(result)")
    }

    private func unlock() {
      let result = pthread_cond_broadcast(condition)
      precondition(result == 0, "pthread_cond_broadcast failed with \(result)")
      let unlocked = pthread_mutex_unlock(mutex)
      precondition(unlocked == 0, "pthread_mutex_unlock failed with \(unlocked)")
    }

    // The time `timeout` from now, on the clock the condition measures its deadlines against.
    private static func deadline(after timeout: Duration) -> timespec {
      var deadline = timespec()
      #if os(WASI)
        _ = timespec_get(&deadline, TIME_UTC)
      #else
        _ = clock_gettime(CLOCK_MONOTONIC, &deadline)
      #endif
      let (seconds, attoseconds) = timeout.components
      deadline.tv_sec += time_t(seconds)
      deadline.tv_nsec += Int(attoseconds / 1_000_000_000)
      if deadline.tv_nsec >= 1_000_000_000 {
        deadline.tv_sec += 1
        deadline.tv_nsec -= 1_000_000_000
      }
      return deadline
    }
  }

  extension ConditionLock: @unchecked Sendable {}
#endif
