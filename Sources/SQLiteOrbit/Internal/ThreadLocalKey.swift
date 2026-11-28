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
  /// A key is created once and never deleted, so it belongs in a `static let`.
  struct ThreadLocalKey: @unchecked Sendable {
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
