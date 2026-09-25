#if canImport(Darwin) || os(Windows)
  import Foundation
#elseif _runtime(_multithreaded)
  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Android)
    import Android
  #elseif canImport(WASILibc)
    import WASILibc
  #endif
#endif

/// The identity of the thread currently running a blocking database access.
struct ThreadID: Equatable {
  #if canImport(Darwin) || os(Windows)
    private let thread: ObjectIdentifier

    static var current: Self { Self(thread: ObjectIdentifier(Thread.current)) }
  #elseif _runtime(_multithreaded)
    private let thread: pthread_t

    static var current: Self { Self(thread: pthread_self()) }

    // POSIX only promises that `pthread_equal` compares pthread identities meaningfully.
    static func == (lhs: Self, rhs: Self) -> Bool {
      pthread_equal(lhs.thread, rhs.thread) != 0
    }
  #else
    // Every blocking access runs on the only runtime thread.
    static var current: Self { Self() }
  #endif
}

// A thread identity is only compared, never dereferenced.
extension ThreadID: @unchecked Sendable {}
