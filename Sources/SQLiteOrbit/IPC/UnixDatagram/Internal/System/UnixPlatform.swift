// The Unix datagram transport's I/O layer reaches the platform's C library through this file, and
// through the backend files for each readiness mechanism, which import the module that mechanism
// lives in: Darwin for kqueue, and CLinuxEvents for epoll and inotify. Nothing else imports a C
// library. How a constant is spelled, which flags a call can take and how `errno` is read are
// settled here, so the rest of the layer needs no guard beyond the one that says it exists at all.
#if canImport(Darwin) || os(Linux) || os(Android)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Android)
    import Android
  #endif

  #if canImport(Darwin)
    // `kevent` names both the event struct and the call that takes it. A call spelled with either
    // name resolves to the struct's initializer, so the call is reached through a name of its own,
    // which both kqueue backends use.
    let systemKevent = kevent
  #endif

  /// The C library calls the layer makes outside its readiness backends, each spelled once, with
  /// the same Swift types on every platform.
  ///
  /// Each call returns what the C call returned and leaves `errno` as the C call left it, so a
  /// failure is read, through ``lastErrorCode``, by the caller that knows what it means.
  enum UnixPlatform {
    /// The `errno` the calling thread's last failed call left behind.
    static var lastErrorCode: Int32 {
      errno
    }

    /// The `errno` values the layer tells apart.
    enum ErrorCode {
      static let interrupted: Int32 = EINTR
      static let tryAgain: Int32 = EAGAIN
      static let wouldBlock: Int32 = EWOULDBLOCK
      static let noBufferSpace: Int32 = ENOBUFS
      static let invalidArgument: Int32 = EINVAL
      static let badDescriptor: Int32 = EBADF
      static let messageTooLong: Int32 = EMSGSIZE
      static let nameTooLong: Int32 = ENAMETOOLONG
      static let noSuchFile: Int32 = ENOENT
      static let connectionRefused: Int32 = ECONNREFUSED
      static let connectionReset: Int32 = ECONNRESET
      static let notConnected: Int32 = ENOTCONN
    }

    // MARK: - Descriptors

    static func closeDescriptor(_ descriptor: Int32) {
      _ = close(descriptor)
    }

    static func setNonBlocking(_ descriptor: Int32) -> Bool {
      let flags = fcntl(descriptor, F_GETFL, 0)
      return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    static func setCloseOnExec(_ descriptor: Int32) -> Bool {
      let flags = fcntl(descriptor, F_GETFD, 0)
      return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    /// Reads into `buffer`, which must not be empty.
    static func readBytes(
      from descriptor: Int32,
      into buffer: UnsafeMutableRawBufferPointer
    ) -> Int {
      read(descriptor, buffer.baseAddress!, buffer.count)
    }

    /// Writes `bytes`, which must not be empty.
    static func writeBytes(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) -> Int {
      write(descriptor, bytes.baseAddress!, bytes.count)
    }

    // MARK: - Files

    static func removeFile(atPath path: String) -> Bool {
      unlink(path) == 0
    }

    /// Renames the file at `source` over the one at `destination`, in one step, so a reader finds
    /// one file or the other and never neither.
    static func renameFile(atPath source: String, toPath destination: String) -> Bool {
      rename(source, destination) == 0
    }

    /// Opens the file at `path` for reading and writing, creating it if needed.
    static func openCreatingFile(atPath path: String) -> Int32 {
      open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o666)
    }

    /// Takes an exclusive `flock` on an open file, waiting for it.
    static func lockExclusively(_ descriptor: Int32) -> Bool {
      flock(descriptor, LOCK_EX) == 0
    }

    // MARK: - Sockets

    /// Creates a nonblocking, close-on-exec Unix-domain datagram socket that raises no `SIGPIPE`.
    static func makeDatagramSocket() throws -> UnixDescriptor {
      #if canImport(Darwin)
        // Darwin cannot set these as it creates the socket, so they follow at once. A fork on
        // another thread in between would hand the child this descriptor for as long as it runs.
        let descriptor = try UnixDescriptor(socket(AF_UNIX, SOCK_DGRAM, 0), from: "socket")
        try descriptor.setNonBlocking()
        try descriptor.setCloseOnExec()
        var enabled: Int32 = 1
        // Darwin refuses a datagram larger than the sender's send buffer with `EMSGSIZE`, and that
        // buffer starts at 2 KiB, so it is raised past the longest datagram any endpoint accepts.
        var sendBufferByteCount: Int32 = 65_536
        let size = socklen_t(MemoryLayout<Int32>.size)
        guard
          setsockopt(descriptor.rawValue, SOL_SOCKET, SO_NOSIGPIPE, &enabled, size) == 0,
          setsockopt(descriptor.rawValue, SOL_SOCKET, SO_SNDBUF, &sendBufferByteCount, size) == 0
        else { throw UnixSystemError.last("socket") }
        return descriptor
      #else
        return try UnixDescriptor(socket(AF_UNIX, socketType, 0), from: "socket")
      #endif
    }

    static func setReceiveBufferByteCount(_ byteCount: Int, of descriptor: Int32) -> Bool {
      var byteCount = Int32(clamping: byteCount)
      let size = socklen_t(MemoryLayout<Int32>.size)
      return setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &byteCount, size) == 0
    }

    static func bindSocket(_ descriptor: Int32, to address: UnixSocketAddress) -> Bool {
      address.withSockAddr { bind(descriptor, $0, $1) } == 0
    }

    static func connectSocket(_ descriptor: Int32, to address: UnixSocketAddress) -> Bool {
      address.withSockAddr { connect(descriptor, $0, $1) } == 0
    }

    /// Sends `bytes`, which must not be empty, as one datagram on a connected socket.
    ///
    /// Nothing here retries `EINTR`: the socket is nonblocking, so neither this nor
    /// ``receiveDatagram(into:from:)`` ever waits in the kernel long enough for a signal to
    /// interrupt it.
    static func sendDatagram(_ bytes: UnsafeRawBufferPointer, on descriptor: Int32) -> Int {
      send(descriptor, bytes.baseAddress!, bytes.count, sendFlags)
    }

    static func receiveDatagram(
      into buffer: UnsafeMutableBufferPointer<UInt8>,
      from descriptor: Int32
    ) -> Int {
      recv(descriptor, buffer.baseAddress!, buffer.count, 0)
    }

    #if canImport(Darwin)
      // Darwin raises no `SIGPIPE` from these sockets, because each is made with `SO_NOSIGPIPE`.
      private static let sendFlags: Int32 = 0
    #else
      // Glibc spells a socket type as a member of an enumeration, where Musl and Bionic spell it
      // as a plain integer macro.
      #if canImport(Glibc)
        private static let socketType =
          Int32(SOCK_DGRAM.rawValue) | Int32(SOCK_NONBLOCK.rawValue)
          | Int32(SOCK_CLOEXEC.rawValue)
      #else
        private static let socketType =
          Int32(SOCK_DGRAM) | Int32(SOCK_NONBLOCK) | Int32(SOCK_CLOEXEC)
      #endif
      private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif
  }

  /// A Unix-domain socket address naming a path.
  struct UnixSocketAddress {
    private var storage = sockaddr_un()
    private let length: socklen_t

    /// - Throws: A ``UnixSystemError`` if `path` contains a NUL or is longer than the platform's
    ///   `sun_path`, which holds 104 bytes on Darwin and 108 on Linux and Android.
    init(path: String) throws {
      let bytes = Array(path.utf8) + [0]
      guard !path.utf8.contains(0) else {
        throw UnixSystemError.invalidArgument("socket path contains NUL")
      }
      guard bytes.count <= MemoryLayout.size(ofValue: self.storage.sun_path) else {
        throw UnixSystemError(operation: "socket path is too long", code: ENAMETOOLONG)
      }
      self.storage.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &self.storage.sun_path) { $0.copyBytes(from: bytes) }
      self.length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count)
      #if canImport(Darwin)
        self.storage.sun_len = UInt8(self.length)
      #endif
    }

    fileprivate func withSockAddr<Result>(
      _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) rethrows -> Result {
      try withUnsafePointer(to: self.storage) { storage in
        try storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, self.length) }
      }
    }
  }
#endif
