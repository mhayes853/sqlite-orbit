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

    /// Whether an endpoint is still there, as ``probe(_:)`` finds it.
    enum Liveness: Equatable, Sendable {
      /// A socket is bound at the path, whether or not whoever holds it is running.
      case alive

      /// Nothing is bound at the path, or nothing is there at all.
      case dead
    }

    let descriptor: UnixDescriptor

    /// The file a socket made by ``bind(path:receiveBufferByteCount:)`` was bound to, which is
    /// how its owner tells whether its path still names it, and `nil` for a connected socket.
    let boundFile: UnixFileIdentity?

    /// Creates a socket bound to `path`, the address peers send to.
    ///
    /// The socket is bound under a hidden name beside `path`, a dot followed by its last
    /// component, and then renamed over `path`. Binding creates the socket's file before the
    /// socket is bound to it, so a peer could otherwise find the file, fail to connect, and take
    /// the endpoint for dead. Renaming means whatever is at `path` is only ever a socket that is
    /// already bound, and it replaces whatever was there, such as this endpoint's own socket
    /// after its file was unlinked, in one step. The hidden name is one byte longer than `path`,
    /// so it is the one that must fit in the platform's `sun_path`.
    ///
    /// - Parameters:
    ///   - path: Where to bind the socket, replacing whatever is there.
    ///   - receiveBufferByteCount: The size of the socket's receive buffer.
    /// - Throws: A ``UnixSystemError`` if the socket cannot be created, bound or renamed into
    ///   place, after which nothing it made is left behind.
    static func bind(path: String, receiveBufferByteCount: Int) throws -> Self {
      let temporaryPath = Self.temporaryPath(binding: path)
      let address = try UnixSocketAddress(path: temporaryPath)
      let descriptor = try UnixPlatform.makeDatagramSocket()
      guard UnixPlatform.setReceiveBufferByteCount(receiveBufferByteCount, of: descriptor.rawValue)
      else { throw UnixSystemError.last("setsockopt") }
      // Left behind if a bind by this endpoint, the only one that binds under this name, died
      // before renaming its socket into place. Binding fails while anything is at the path.
      _ = UnixPlatform.removeFile(atPath: temporaryPath)
      guard UnixPlatform.bindSocket(descriptor.rawValue, to: address) else {
        throw UnixSystemError.last("bind")
      }
      do {
        guard let boundFile = UnixPlatform.fileIdentity(atPath: temporaryPath) else {
          throw UnixSystemError.last("stat")
        }
        guard UnixPlatform.renameFile(atPath: temporaryPath, toPath: path) else {
          throw UnixSystemError.last("rename")
        }
        return Self(descriptor: descriptor, boundFile: boundFile)
      } catch {
        _ = UnixPlatform.removeFile(atPath: temporaryPath)
        throw error
      }
    }

    /// Finds whether a socket is bound at `path` by connecting to it, which sends nothing and
    /// which the socket's owner never hears about.
    ///
    /// Only a connect failing with `ENOENT`, nothing at the path, or `ECONNREFUSED`, a file no
    /// socket is bound to any more, means the endpoint is dead. Every other outcome, including a
    /// failure to try at all, means it is alive: taking a live endpoint for dead costs it its
    /// files, where taking a dead one for alive only puts off removing them.
    static func probe(_ path: String) -> Liveness {
      guard let address = try? UnixSocketAddress(path: path) else { return .alive }
      guard let descriptor = try? UnixPlatform.makeDatagramSocket() else { return .alive }
      return withExtendedLifetime(descriptor) {
        guard !UnixPlatform.connectSocket(descriptor.rawValue, to: address) else { return .alive }
        let code = UnixPlatform.lastErrorCode
        let isDead =
          code == UnixPlatform.ErrorCode.noSuchFile
          || code == UnixPlatform.ErrorCode.connectionRefused
        return isDead ? .dead : .alive
      }
    }

    /// The hidden name ``bind(path:receiveBufferByteCount:)`` binds under before renaming the
    /// socket to `path`: `path` with a dot before its last component.
    static func temporaryPath(binding path: String) -> String {
      guard let slash = path.lastIndex(of: "/") else { return ".\(path)" }
      let name = path.index(after: slash)
      return "\(path[..<name]).\(path[name...])"
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
      return Self(descriptor: descriptor, boundFile: nil)
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
