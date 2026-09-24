// Only the pthread executor starts threads of its own, so this is built only where that executor
// is. Darwin and Windows keep libdispatch, and a runtime without threads cannot start one.
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

  /// The identity of a thread, for telling whether two are the same one.
  ///
  /// `pthread_t` is an integer on Glibc, a `long` on Android and a pointer on Musl and WASI, and on
  /// none of them does POSIX promise that `==` compares it meaningfully. `pthread_equal` does.
  struct ThreadID: Equatable {
    private let thread: pthread_t

    /// The thread this is read on.
    static var current: Self {
      Self(thread: pthread_self())
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      pthread_equal(lhs.thread, rhs.thread) != 0
    }
  }

  // A thread's identity is only ever compared, never dereferenced, so sharing one is safe even
  // where it is spelled as a pointer.
  extension ThreadID: @unchecked Sendable {}

  /// Starts threads that nothing joins, each running one closure and ending when it returns.
  enum DetachedThread {
    /// Starts a thread running `body`.
    ///
    /// - Parameters:
    ///   - name: What the thread is called in debuggers, hang reports and crash tombstones. Linux
    ///     and Android keep only its first 15 bytes.
    ///   - body: The work the thread does before it ends.
    static func spawn(name: String, _ body: @escaping @Sendable () -> Void) {
      let run = Context {
        nameCurrentThread(name)
        body()
      }
      let context = Unmanaged.passRetained(run).toOpaque()

      var attributes = pthread_attr_t()
      precondition(pthread_attr_init(&attributes) == 0, "pthread_attr_init failed")
      defer { _ = pthread_attr_destroy(&attributes) }
      precondition(
        pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED)) == 0,
        "pthread_attr_setdetachstate failed"
      )
      // Musl gives a new thread 128 KiB of stack, where Glibc gives 8 MiB and Bionic about 1 MiB.
      // SQLite's parser and a deep decode both recurse, so a thread is given at least a mebibyte,
      // and a platform that already gives more keeps its own default.
      var stackSize = 0
      precondition(
        pthread_attr_getstacksize(&attributes, &stackSize) == 0,
        "pthread_attr_getstacksize failed"
      )
      if stackSize < minimumStackSize {
        precondition(
          pthread_attr_setstacksize(&attributes, minimumStackSize) == 0,
          "pthread_attr_setstacksize failed"
        )
      }

      #if canImport(Musl) || os(WASI)
        var thread: pthread_t? = nil
      #else
        var thread = pthread_t()
      #endif
      // The context is retained for the thread and released by it, so the thread owns the closure
      // it runs for as long as it runs. Bionic has declared the argument both nullable and not,
      // and widening it to an optional first reads either declaration.
      let result = pthread_create(
        &thread,
        &attributes,
        { context in
          Unmanaged<Context>.fromOpaque((context as UnsafeMutableRawPointer?)!)
            .takeRetainedValue()
            .run()
          return nil
        },
        context
      )
      guard result == 0 else {
        Unmanaged<Context>.fromOpaque(context).release()
        fatalError("pthread_create failed with \(result)")
      }
    }

    private static let minimumStackSize = 1 << 20

    // Linux and Android read a thread's name from its `comm` file, and writing that file is a way
    // to name a thread Swift can reach: Glibc and Musl declare `pthread_setname_np` only under
    // `_GNU_SOURCE`, which Swift does not read their headers with. A thread that goes unnamed
    // still runs, so a failure is ignored.
    private static func nameCurrentThread(_ name: String) {
      #if os(Linux) || os(Android)
        let descriptor = open("/proc/thread-self/comm", O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        var name = name
        _ = name.withUTF8 { write(descriptor, $0.baseAddress, $0.count) }
        _ = close(descriptor)
      #endif
    }

    // The closure a thread runs, boxed to pass through `pthread_create`'s context pointer.
    fileprivate final class Context {
      let run: @Sendable () -> Void

      init(_ run: @escaping @Sendable () -> Void) {
        self.run = run
      }
    }
  }
#endif
