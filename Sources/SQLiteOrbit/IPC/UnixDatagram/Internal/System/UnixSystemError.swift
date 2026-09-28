#if canImport(Darwin) || os(Linux) || os(Android)
  /// A failed system call, named by what it was doing, and the `errno` it failed with.
  struct UnixSystemError: Error, Equatable, CustomStringConvertible, Sendable {
    let operation: String
    let code: Int32

    var description: String {
      "\(self.operation) failed with errno \(self.code)"
    }

    /// The error the calling thread's last failed system call left behind.
    static func last(_ operation: String) -> Self {
      Self(operation: operation, code: UnixPlatform.lastErrorCode)
    }

    static func invalidArgument(_ operation: String) -> Self {
      Self(operation: operation, code: UnixPlatform.ErrorCode.invalidArgument)
    }

    static func messageTooLong(_ operation: String) -> Self {
      Self(operation: operation, code: UnixPlatform.ErrorCode.messageTooLong)
    }
  }
#endif
