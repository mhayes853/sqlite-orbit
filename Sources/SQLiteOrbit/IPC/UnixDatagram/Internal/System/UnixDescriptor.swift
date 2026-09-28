#if canImport(Darwin) || os(Linux) || os(Android)
  /// An open file descriptor, closed exactly once, when the last reference to it goes.
  ///
  /// It is a class rather than a noncopyable struct so that it can live in ordinary collections,
  /// such as the sockets an endpoint keeps for each of its peers. Whatever uses ``rawValue`` must
  /// keep the descriptor itself alive for as long as it does.
  final class UnixDescriptor: Sendable {
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
