// Every platform but Windows declares `nanosleep`, including WASI, where it blocks the only thread
// on a runtime without threads.
#if !os(Windows)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Android)
    import Android
  #elseif canImport(WASILibc)
    import WASILibc
  #endif

  /// The thread that is running the caller.
  ///
  /// Foundation's `Thread` is missing from FoundationEssentials, so what the package needs of it
  /// is here, over the C library.
  enum CurrentThread {
    /// Blocks the calling thread for `duration`, or not at all if it is not positive.
    ///
    /// A signal handled partway through does not end the sleep early: it goes on for whatever
    /// time was left.
    static func sleep(for duration: Duration) {
      guard duration > .zero else { return }
      let (seconds, attoseconds) = duration.components
      var request = timespec(
        tv_sec: time_t(clamping: seconds),
        tv_nsec: Int(attoseconds / 1_000_000_000)
      )
      var remaining = timespec()
      while nanosleep(&request, &remaining) != 0, errno == EINTR {
        request = remaining
      }
    }
  }
#endif
