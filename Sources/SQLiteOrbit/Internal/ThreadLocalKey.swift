#if _runtime(_multithreaded)
  #if os(Windows)
    import WinSDK
  #elseif canImport(Darwin)
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

  /// A slot holding one raw pointer per thread, which a C callback that captures nothing can still
  /// reach.
  ///
  /// The system has a fixed number of these slots, around a thousand on Linux and Windows, so a
  /// key belongs in a `static let`, which lives as long as the process. It cannot be copied, and
  /// it frees its slot when it goes, so a key made anywhere shorter-lived gives the slot back
  /// rather than leaking it.
  ///
  /// A pointer the key holds is borrowed: nothing is released for a thread when it exits, or when
  /// the key goes.
  struct ThreadLocalKey: ~Copyable, @unchecked Sendable {
    #if os(Windows)
      private let index: DWORD
    #else
      private let key: pthread_key_t
    #endif

    /// Creates the key, stopping the process with `failureMessage` if the system has none left.
    init(failureMessage: String) {
      #if os(Windows)
        // `TLS_OUT_OF_INDEXES` is a cast macro, which Swift does not import.
        let index = TlsAlloc()
        precondition(index != DWORD.max, failureMessage)
        self.index = index
      #else
        var key = pthread_key_t()
        let code = pthread_key_create(&key, nil)
        precondition(code == 0, failureMessage)
        self.key = key
      #endif
    }

    deinit {
      #if os(Windows)
        TlsFree(self.index)
      #else
        pthread_key_delete(self.key)
      #endif
    }

    /// The current thread's pointer, `nil` until the thread sets one.
    var value: UnsafeMutableRawPointer? {
      get {
        #if os(Windows)
          TlsGetValue(self.index)
        #else
          pthread_getspecific(self.key)
        #endif
      }
      nonmutating set {
        #if os(Windows)
          TlsSetValue(self.index, newValue)
        #else
          pthread_setspecific(self.key, newValue)
        #endif
      }
    }
  }
#endif
