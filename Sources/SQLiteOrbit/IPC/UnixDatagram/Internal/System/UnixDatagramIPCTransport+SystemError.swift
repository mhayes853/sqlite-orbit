#if canImport(Darwin) || os(Linux) || os(Android)
  extension UnixDatagramIPCTransport.SystemError {
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
