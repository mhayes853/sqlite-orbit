#if canImport(Darwin) && canImport(os)
  import os
#elseif canImport(Synchronization)
  import Synchronization
#endif

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
