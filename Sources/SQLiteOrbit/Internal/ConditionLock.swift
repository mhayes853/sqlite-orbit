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

  /// A pthread mutex and a condition variable waited on under it.
  ///
  /// `Lock` cannot stand in for the mutex: a `Synchronization.Mutex` has no condition variable to
  /// pair with. Staying on raw pthreads also keeps the thread sanitizer useful, because on Linux it
  /// models a pthread mutex as ordering the accesses made under it and a `Synchronization.Mutex`
  /// as ordering nothing.
  struct ConditionLock: ~Copyable {
    // Both are allocated rather than stored inline because a pthread object must not move once it
    // is initialized, and nothing about a Swift value promises it an address that holds still.
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private let condition: UnsafeMutablePointer<pthread_cond_t>

    init() {
      self.mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
      self.mutex.initialize(to: pthread_mutex_t())
      self.condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
      self.condition.initialize(to: pthread_cond_t())
      precondition(pthread_mutex_init(mutex, nil) == 0, "pthread_mutex_init failed")

      var attributes = pthread_condattr_t()
      precondition(pthread_condattr_init(&attributes) == 0, "pthread_condattr_init failed")
      defer { _ = pthread_condattr_destroy(&attributes) }
      #if !os(WASI)
        // A timed wait measures against the monotonic clock, so setting the wall clock neither
        // cuts a wait short nor stretches it out.
        precondition(
          pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC) == 0,
          "pthread_condattr_setclock failed"
        )
      #endif
      precondition(pthread_cond_init(condition, &attributes) == 0, "pthread_cond_init failed")
    }

    deinit {
      _ = pthread_cond_destroy(condition)
      condition.deinitialize(count: 1)
      condition.deallocate()
      _ = pthread_mutex_destroy(mutex)
      mutex.deinitialize(count: 1)
      mutex.deallocate()
    }

    borrowing func lock() {
      let result = pthread_mutex_lock(mutex)
      precondition(result == 0, "pthread_mutex_lock failed with \(result)")
    }

    borrowing func unlock() {
      let result = pthread_mutex_unlock(mutex)
      precondition(result == 0, "pthread_mutex_unlock failed with \(result)")
    }

    borrowing func withLock<Result: ~Copyable, E: Error>(
      _ body: () throws(E) -> Result
    ) throws(E) -> Result {
      lock()
      defer { unlock() }
      return try body()
    }

    /// Releases the mutex until the condition is signalled, then takes it back.
    ///
    /// A wait can also end without a signal, so the caller must hold the mutex and test what it
    /// is waiting for in a loop.
    borrowing func wait() {
      let result = pthread_cond_wait(condition, mutex)
      precondition(result == 0, "pthread_cond_wait failed with \(result)")
    }

    /// Releases the mutex until the condition is signalled or `timeout` passes, then takes it back.
    ///
    /// - Returns: `false` when the wait ended because `timeout` passed.
    borrowing func wait(timeout: Duration) -> Bool {
      var deadline = Self.now()
      let (seconds, attoseconds) = timeout.components
      deadline.tv_sec += time_t(seconds)
      deadline.tv_nsec += Int(attoseconds / 1_000_000_000)
      if deadline.tv_nsec >= 1_000_000_000 {
        deadline.tv_sec += 1
        deadline.tv_nsec -= 1_000_000_000
      }
      let result = pthread_cond_timedwait(condition, mutex, &deadline)
      precondition(result == 0 || result == ETIMEDOUT, "pthread_cond_timedwait failed with \(result)")
      return result == 0
    }

    borrowing func signal() {
      let result = pthread_cond_signal(condition)
      precondition(result == 0, "pthread_cond_signal failed with \(result)")
    }

    borrowing func broadcast() {
      let result = pthread_cond_broadcast(condition)
      precondition(result == 0, "pthread_cond_broadcast failed with \(result)")
    }

    // The time on the clock the condition measures its deadlines against.
    private static func now() -> timespec {
      var now = timespec()
      #if os(WASI)
        // wasi-libc spells its clock ids as the addresses of C globals, which Swift cannot import,
        // so the condition keeps its default wall clock and C11 reads it. Setting the clock can then
        // end a timed wait early or late, which the idle timeout this serves can afford.
        _ = timespec_get(&now, TIME_UTC)
      #else
        _ = clock_gettime(CLOCK_MONOTONIC, &now)
      #endif
      return now
    }
  }

  extension ConditionLock: @unchecked Sendable {}
#endif
