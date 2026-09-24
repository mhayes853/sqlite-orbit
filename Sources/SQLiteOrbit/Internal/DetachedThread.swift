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
    ///   - name: What the thread is called in debuggers, hang reports and crash tombstones. Where
    ///     the platform caps a name's length, it is cut short to fit.
    ///   - body: The work the thread does before it ends.
    static func spawn(name: String, _ body: @escaping @Sendable () -> Void) {
      let context = Unmanaged.passRetained(Context(name: name, body: body)).toOpaque()

      var attributes = pthread_attr_t()
      precondition(pthread_attr_init(&attributes) == 0, "pthread_attr_init failed")
      defer { _ = pthread_attr_destroy(&attributes) }
      precondition(
        pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED)) == 0,
        "pthread_attr_setdetachstate failed"
      )

      #if canImport(Musl) || os(WASI)
        var thread: pthread_t? = nil
      #else
        var thread = pthread_t()
      #endif
      // The context is retained for the thread and released by it, so the thread owns the closure
      // it runs for as long as it runs. Bionic has declared the argument both nullable and not,
      // and widening it to an optional first reads either declaration.
      let result = pthread_create(&thread, &attributes, { context in
        Unmanaged<Context>.fromOpaque((context as UnsafeMutableRawPointer?)!)
          .takeRetainedValue()
          .run()
        return nil
      }, context)
      guard result == 0 else {
        Unmanaged<Context>.fromOpaque(context).release()
        fatalError("pthread_create failed with \(result)")
      }
    }

    #if !os(WASI)
      // Linux and Android refuse a name longer than 15 bytes outright rather than truncating it,
      // so it is cut short here, where a multi-byte character can be kept whole.
      private static let maximumNameLength = 15

      fileprivate static func truncatedName(_ name: String) -> String {
        var truncated = ""
        var length = 0
        for scalar in name.unicodeScalars {
          length += UTF8.width(scalar)
          guard length <= maximumNameLength else { break }
          truncated.unicodeScalars.append(scalar)
        }
        return truncated
      }
    #endif

    fileprivate final class Context {
      let name: String
      let body: @Sendable () -> Void

      init(name: String, body: @escaping @Sendable () -> Void) {
        self.name = name
        self.body = body
      }

      func run() {
        #if !os(WASI)
          // A thread can only be named once it exists, and naming itself is the one way every
          // platform here allows.
          _ = setThreadName?(pthread_self(), DetachedThread.truncatedName(name))
        #endif
        body()
      }
    }
  }

  #if canImport(Glibc) || canImport(Musl)
    // Glibc and Musl declare `pthread_setname_np` only under `_GNU_SOURCE`, which Swift does not
    // read their headers with, so it is looked up by name instead. Both have had it for more than a
    // decade, and a thread that goes unnamed still runs.
    private let setThreadName: (@convention(c) (pthread_t, UnsafePointer<CChar>) -> Int32)? = {
      guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "pthread_setname_np") else { return nil }
      return unsafeBitCast(
        symbol,
        to: (@convention(c) (pthread_t, UnsafePointer<CChar>) -> Int32).self
      )
    }()
  #elseif os(Android)
    private let setThreadName: (@convention(c) (pthread_t, UnsafePointer<CChar>) -> Int32)? =
      pthread_setname_np
  #endif
#endif
