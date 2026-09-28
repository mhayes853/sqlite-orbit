#if canImport(Darwin) || os(Linux) || os(Android)
  /// An open file descriptor, closed exactly once, when the one value that owns it goes.
  ///
  /// It cannot be copied, so nothing can close it behind its owner's back or keep it open after.
  /// Whatever uses ``rawValue`` must keep the descriptor itself alive for as long as it does,
  /// since it may close as soon as its owner is last used rather than at the end of a scope.
  struct UnixDescriptor: ~Copyable, Sendable {
    let rawValue: Int32

    /// Takes ownership of the descriptor a call returned.
    ///
    /// - Parameters:
    ///   - rawValue: What the call returned, which is negative if it failed.
    ///   - operation: What the call was doing, to name in the error if it failed.
    /// - Throws: A ``UnixSystemError`` if the call failed.
    init(_ rawValue: Int32, from operation: String) throws {
      guard rawValue >= 0 else { throw UnixSystemError.last(operation) }
      self.rawValue = rawValue
    }

    deinit {
      UnixPlatform.closeDescriptor(self.rawValue)
    }
  }
#endif
