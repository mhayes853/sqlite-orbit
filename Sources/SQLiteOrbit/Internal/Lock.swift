#if canImport(Darwin) && canImport(os)
  import os
#elseif canImport(Synchronization)
  import Synchronization
#endif

/// A mutex guarding a value.
///
/// `Synchronization.Mutex` is the natural spelling, but it is only available from macOS 15 while
/// this package supports macOS 13, so Darwin gets an unfair lock around a separate allocation
/// instead. Every other platform uses `Mutex` directly, which stores the value inline.
///
/// The type is noncopyable so that neither spelling can be duplicated out from under the value it
/// guards.
struct Lock<Value: ~Copyable>: ~Copyable {
  #if canImport(Darwin) && canImport(os)
    private let lock = OSAllocatedUnfairLock()
    private let storage: UnsafeMutablePointer<Value>
  #else
    private let lock: Mutex<Value>
  #endif

  init(_ value: consuming sending Value) {
    #if canImport(Darwin) && canImport(os)
      self.storage = UnsafeMutablePointer<Value>.allocate(capacity: 1)
      self.storage.initialize(to: value)
    #else
      self.lock = Mutex(value)
    #endif
  }

  deinit {
    #if canImport(Darwin) && canImport(os)
      self.storage.deinitialize(count: 1)
      self.storage.deallocate()
    #endif
  }

  borrowing func withLock<Result: ~Copyable, E: Error>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result {
    #if canImport(Darwin) && canImport(os)
      self.lock.lock()
      defer { self.lock.unlock() }
      return try body(&self.storage.pointee)
    #else
      return try self.lock.withLock(body)
    #endif
  }
}

extension Lock: @unchecked Sendable where Value: ~Copyable {}
