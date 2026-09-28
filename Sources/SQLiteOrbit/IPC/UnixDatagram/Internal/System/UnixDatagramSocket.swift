#if canImport(Darwin) || os(Linux) || os(Android)
  /// A nonblocking Unix-domain datagram socket, either bound to the path peers send to or
  /// connected to one peer's.
  ///
  /// Every judgment of what a failed call means is made here, so what reaches the caller is
  /// already an outcome: a peer with no room, a peer that is gone, or a real failure.
  struct UnixDatagramSocket: ~Copyable, Sendable {
    /// What became of a datagram offered to a connected socket.
    enum SendOutcome: Equatable {
      /// The peer's receive queue took it.
      case sent

      /// The peer's receive queue is full. Nothing is wrong, and the datagram can be sent again
      /// once the peer drains.
      case full

      /// Nothing reads from the peer's socket any more.
      case peerGone

      /// The send failed for some other reason.
      case failed(UnixSystemError)
    }

    let descriptor: UnixDescriptor

    /// Creates a socket bound to `path`, the address peers send to.
    ///
    /// - Parameters:
    ///   - path: Where to bind the socket, which must not exist yet.
    ///   - receiveBufferByteCount: The size of the socket's receive buffer.
    /// - Throws: A ``UnixSystemError`` if the socket cannot be created and bound.
    static func bind(path: String, receiveBufferByteCount: Int) throws -> Self {
      let address = try UnixSocketAddress(path: path)
      let descriptor = try UnixPlatform.makeDatagramSocket()
      guard
        UnixPlatform.setReceiveBufferByteCount(receiveBufferByteCount, of: descriptor.rawValue),
        UnixPlatform.bindSocket(descriptor.rawValue, to: address)
      else { throw UnixSystemError.last("bind") }
      return Self(descriptor: descriptor)
    }

    /// Creates an unbound socket connected to the one bound at `path`.
    ///
    /// Sending on it needs no address, and on Linux it reports itself unwritable while the peer's
    /// receive queue is full, which ``UnixEventQueue/watchWritable(_:)`` rests on.
    ///
    /// - Returns: The socket, or `nil` if nothing is bound at `path` any more.
    /// - Throws: A ``UnixSystemError`` if the socket cannot be created or connected for any other
    ///   reason.
    static func connect(to path: String) throws -> Self? {
      let address = try UnixSocketAddress(path: path)
      let descriptor = try UnixPlatform.makeDatagramSocket()
      guard UnixPlatform.connectSocket(descriptor.rawValue, to: address) else {
        let code = UnixPlatform.lastErrorCode
        if Self.peerGoneCodes.contains(code) { return nil }
        throw UnixSystemError(operation: "connect", code: code)
      }
      return Self(descriptor: descriptor)
    }

    /// Sends `bytes` as one datagram, on a socket made by ``connect(to:)``.
    func send(_ bytes: [UInt8]) -> SendOutcome {
      let count = bytes.withUnsafeBytes {
        UnixPlatform.sendDatagram($0, on: self.descriptor.rawValue)
      }
      if count == bytes.count { return .sent }
      guard count < 0 else { return .failed(.messageTooLong("send")) }
      let code = UnixPlatform.lastErrorCode
      if Self.fullCodes.contains(code) { return .full }
      if Self.peerGoneCodes.contains(code) { return .peerGone }
      return .failed(UnixSystemError(operation: "send", code: code))
    }

    /// Receives one datagram into `buffer`, on a socket made by ``bind(path:receiveBufferByteCount:)``.
    ///
    /// - Returns: The datagram's length, or `nil` once the queue is empty or the socket fails. A
    ///   datagram longer than `buffer` is cut short, so a caller that makes `buffer` one byte
    ///   longer than it accepts can tell one that was too long by its length.
    func receive(into buffer: UnsafeMutableBufferPointer<UInt8>) -> Int? {
      let count = UnixPlatform.receiveDatagram(into: buffer, from: self.descriptor.rawValue)
      return count >= 0 ? count : nil
    }

    /// What a full receive queue fails a send with: `EAGAIN` on Linux, and `ENOBUFS` on Darwin.
    private static let fullCodes: Set<Int32> = [
      UnixPlatform.ErrorCode.tryAgain,
      UnixPlatform.ErrorCode.wouldBlock,
      UnixPlatform.ErrorCode.noBufferSpace
    ]

    /// What a peer that is gone fails a connect or a send with.
    ///
    /// A path with nothing behind it fails a connect with `ENOENT`, and one whose socket nobody
    /// holds any more with `ECONNREFUSED`. A socket connected to a peer that then closes gets
    /// `ECONNREFUSED` on Linux and `ECONNRESET` on Darwin, and `ENOTCONN` on either once the
    /// kernel has disconnected it.
    private static let peerGoneCodes: Set<Int32> = [
      UnixPlatform.ErrorCode.noSuchFile,
      UnixPlatform.ErrorCode.connectionRefused,
      UnixPlatform.ErrorCode.connectionReset,
      UnixPlatform.ErrorCode.notConnected
    ]
  }
#endif
