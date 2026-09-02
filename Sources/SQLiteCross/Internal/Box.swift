#if GRDB
  /// Carries a Swift value through SQLite's `void *` user data, which SQLite owns for as long as
  /// the collation or function is registered and hands to its destructor when it is dropped.
  final class Box<Value> {
    let value: Value

    private init(_ value: Value) {
      self.value = value
    }

    static func retain(_ value: Value) -> UnsafeMutableRawPointer {
      Unmanaged.passRetained(Box(value)).toOpaque()
    }

    static func value(in pointer: UnsafeMutableRawPointer?) -> Value {
      Unmanaged<Box>.fromOpaque(pointer!).takeUnretainedValue().value
    }

    static func release(_ pointer: UnsafeMutableRawPointer?) {
      guard let pointer else { return }
      Unmanaged<Box>.fromOpaque(pointer).release()
    }
  }
#endif
