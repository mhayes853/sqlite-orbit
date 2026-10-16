#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Android)
  import Android
#elseif canImport(WASILibc)
  import WASILibc
#endif

// A library's step entry point is a C function pointer, which captures nothing, so an interceptor
// installed with `withStatementStepInterceptor` cannot be stored in the table as it is. The
// interceptor is kept on the installing thread instead, and the table gets a trampoline that finds
// it there. The interceptor's operation is synchronous, so the statements it steps are stepped on
// that thread.
//
// Each depth of nesting on a thread has a trampoline of its own. An interceptor is handed the step
// entry point that was installed before it, which for a nested interceptor is the trampoline of the
// depth below, so calling it reaches the next interceptor out, while a statement stepped from inside
// an interceptor still starts from the innermost one. Two connections intercepted on the same
// thread take different depths, so each table reaches its own interceptor.
enum SQLiteStepInterception {
  typealias Step = (OpaquePointer?) -> Int32

  private struct Frame {
    let depth: Int
    let step: Step
    let previous: UnsafeMutablePointer<Frame>?
  }

  /// Makes `step`, an interceptor already composed with the entry point it wraps, the one at the
  /// next depth of the current thread, returning the entry point that reaches it.
  ///
  /// Every call must be balanced by ``pop()`` on the same thread, innermost first.
  static func push(_ step: @escaping Step) -> @convention(c) (OpaquePointer?) -> Int32 {
    let previous = top
    let depth = previous.map { $0.pointee.depth + 1 } ?? 0
    precondition(
      depth < trampolines.count,
      "Statement step interceptors are nested more than \(trampolines.count) deep on one thread."
    )
    let frame = UnsafeMutablePointer<Frame>.allocate(capacity: 1)
    frame.initialize(to: Frame(depth: depth, step: step, previous: previous))
    top = frame
    return trampolines[depth]
  }

  /// Removes the innermost interceptor of the current thread.
  static func pop() {
    guard let frame = top else { return }
    top = frame.pointee.previous
    frame.deinitialize(count: 1)
    frame.deallocate()
  }

  private static func step(depth: Int, _ statement: OpaquePointer?) -> Int32 {
    var frame = top
    while let current = frame {
      if current.pointee.depth == depth { return current.pointee.step(statement) }
      frame = current.pointee.previous
    }
    fatalError(
      """
      A statement was stepped on a thread other than the one that intercepted its connection's \
      steps. Statements must be stepped synchronously within withStatementStepInterceptor.
      """
    )
  }

  private static let trampolines: [@convention(c) (OpaquePointer?) -> Int32] = [
    { step(depth: 0, $0) },
    { step(depth: 1, $0) },
    { step(depth: 2, $0) },
    { step(depth: 3, $0) },
    { step(depth: 4, $0) },
    { step(depth: 5, $0) },
    { step(depth: 6, $0) },
    { step(depth: 7, $0) }
  ]

  #if !_runtime(_multithreaded)
    // With one runtime thread, the wrappers can live in process storage.
    nonisolated(unsafe) private static var top: UnsafeMutablePointer<Frame>?
  #else
    private static let key: pthread_key_t = {
      var key = pthread_key_t()
      let code = pthread_key_create(&key, nil)
      precondition(code == 0, "Could not create the thread key statement step interceptors are found by.")
      return key
    }()

    private static var top: UnsafeMutablePointer<Frame>? {
      get { pthread_getspecific(key)?.assumingMemoryBound(to: Frame.self) }
      set { pthread_setspecific(key, newValue) }
    }
  #endif
}
