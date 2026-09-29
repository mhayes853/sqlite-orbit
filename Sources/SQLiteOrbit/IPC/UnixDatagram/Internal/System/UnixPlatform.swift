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
  /// failure is read, through ``lastErrorCode``, by the caller that knows what it means. Where
  /// noted, a call a signal interrupts is made again rather than failing with `EINTR`.
  enum UnixPlatform {
    /// The `errno` the calling thread's last failed call left behind.
    static var lastErrorCode: Int32 {
      errno
    }

    /// The `errno` values the layer tells apart.
    enum ErrorCode {
      static let interrupted: Int32 = EINTR
      /// Also `EAGAIN`, which is the same value on every platform this supports.
      static let wouldBlock: Int32 = EWOULDBLOCK
      static let noBufferSpace: Int32 = ENOBUFS
      static let invalidArgument: Int32 = EINVAL
      static let messageTooLong: Int32 = EMSGSIZE
      static let noSuchFile: Int32 = ENOENT
      static let connectionRefused: Int32 = ECONNREFUSED
      static let connectionReset: Int32 = ECONNRESET
      static let notConnected: Int32 = ENOTCONN
      static let notEmpty: Int32 = ENOTEMPTY
      static let fileExists: Int32 = EEXIST
    }

    // MARK: - Descriptors

    static func closeDescriptor(_ descriptor: Int32) {
      _ = close(descriptor)
    }

    /// Reads into `buffer`, which must not be empty, retrying a read a signal interrupts.
    static func readBytes(
      from descriptor: Int32,
      into buffer: UnsafeMutableRawBufferPointer
    ) -> Int {
      while true {
        let count = read(descriptor, buffer.baseAddress!, buffer.count)
        if count >= 0 || errno != EINTR { return count }
      }
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

    /// Sets the access and modification times of the file at `path`, whatever kind it is, to
    /// now, which needs the caller to own it or be able to write to it.
    static func touchFile(atPath path: String) -> Bool {
      utimes(path, nil) == 0
    }

    /// Removes the directory at `path` if it is empty.
    ///
    /// A directory that is not empty fails with `ENOTEMPTY`, or on some systems `EEXIST`, and one
    /// that is not there with `ENOENT`.
    static func removeDirectory(atPath path: String) -> Bool {
      rmdir(path) == 0
    }

    /// Opens the file at `path` for reading and writing, creating it if needed.
    static func openCreatingFile(atPath path: String) -> Int32 {
      open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o666)
    }

    /// Opens the file at `path` for reading, failing with `ENOENT` rather than creating it.
    static func openExistingFile(atPath path: String) -> Int32 {
      open(path, O_RDONLY | O_CLOEXEC)
    }

    /// Takes an exclusive `flock` on an open file without waiting, failing with `EWOULDBLOCK` if
    /// somebody else holds it.
    static func tryLockExclusively(_ descriptor: Int32) -> Bool {
      flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    /// Creates the directory at `path`, and each missing directory above it, as
    /// `FileManager.createDirectory(atPath:withIntermediateDirectories:)` does. A directory
    /// already there, including one another process creates meanwhile, is left as it is.
    ///
    /// - Throws: A ``UnixSystemError`` if a directory cannot be created, or if something other
    ///   than a directory is in the way, with `EEXIST`.
    static func createDirectory(atPath path: String) throws {
      if mkdir(path, 0o777) == 0 { return }
      switch errno {
      case EEXIST:
        break
      case ENOENT:
        let parent = FilePath.deletingLastComponent(of: path)
        guard parent != FilePath.droppingTrailingSlashes(path), !parent.isEmpty else {
          throw UnixSystemError.last("mkdir")
        }
        try Self.createDirectory(atPath: parent)
        if mkdir(path, 0o777) == 0 { return }
        guard errno == EEXIST else { throw UnixSystemError.last("mkdir") }
      default:
        throw UnixSystemError.last("mkdir")
      }
      var status = stat()
      guard stat(path, &status) == 0 else { throw UnixSystemError.last("stat") }
      guard mode_t(status.st_mode) & S_IFMT == S_IFDIR else {
        throw UnixSystemError(operation: "mkdir", code: EEXIST)
      }
    }

    /// The names of what is in the directory at `path`, in no particular order, leaving out `.`
    /// and `..`.
    ///
    /// - Throws: A ``UnixSystemError`` if the directory cannot be read, with `ENOENT` if it is
    ///   not there.
    static func contentsOfDirectory(atPath path: String) throws -> [String] {
      guard let directory = opendir(path) else { throw UnixSystemError.last("opendir") }
      defer { closedir(directory) }
      var names: [String] = []
      while true {
        errno = 0
        guard let entry = readdir(directory) else {
          guard errno == 0 else { throw UnixSystemError.last("readdir") }
          return names
        }
        let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
          String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name != "." && name != ".." {
          names.append(name)
        }
      }
    }

    /// Everything in the file at `path`.
    ///
    /// - Throws: A ``UnixSystemError`` if it cannot be read, with `ENOENT` if nothing is there.
    static func contentsOfFile(atPath path: String) throws -> [UInt8] {
      let descriptor = try UnixDescriptor(Self.openExistingFile(atPath: path), from: "open")
      var contents: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = buffer.withUnsafeMutableBytes {
          Self.readBytes(from: descriptor.rawValue, into: $0)
        }
        guard count >= 0 else { throw UnixSystemError.last("read") }
        guard count > 0 else { return contents }
        contents.append(contentsOf: buffer[..<count])
      }
    }

    /// Writes `bytes` to the file at `path`, creating it if it is not there and replacing what it
    /// held if it is, in place, as `Data.write(to:)` does without `.atomic`.
    ///
    /// - Throws: A ``UnixSystemError`` if it cannot be written, with `ENOENT` if its directory is
    ///   not there.
    static func writeFile(_ bytes: [UInt8], atPath path: String) throws {
      let descriptor = try UnixDescriptor(
        open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666),
        from: "open"
      )
      var written = 0
      while written < bytes.count {
        let count = bytes.withUnsafeBytes {
          Self.writeBytes(UnsafeRawBufferPointer(rebasing: $0[written...]), to: descriptor.rawValue)
        }
        if count < 0 {
          guard errno == EINTR else { throw UnixSystemError.last("write") }
          continue
        }
        written += count
      }
    }

    /// How long before now the file at `path` itself, not what a symbolic link there names, was
    /// last modified, by the system's clock, or `nil` if it cannot be looked up.
    ///
    /// A file modified after now, by a clock set back, has a negative age.
    static func ageOfFile(atPath path: String) -> Duration? {
      var status = stat()
      var now = timespec()
      guard lstat(path, &status) == 0, clock_gettime(CLOCK_REALTIME, &now) == 0 else {
        return nil
      }
      #if canImport(Darwin)
        let modified = status.st_mtimespec
      #else
        let modified = status.st_mtim
      #endif
      return .seconds(Int64(now.tv_sec) - Int64(modified.tv_sec))
        + .nanoseconds(Int64(now.tv_nsec) - Int64(modified.tv_nsec))
    }

    /// Which file the path `path` names now, following a symbolic link.
    ///
    /// - Returns: The file's identity, or `nil` if it cannot be looked up, as when nothing is
    ///   at `path`.
    static func fileIdentity(atPath path: String) -> UnixFileIdentity? {
      UnixFileIdentity { stat(path, &$0) }
    }

    /// Which file an open descriptor refers to, which stays the same however the file is renamed
    /// or unlinked. A socket's descriptor names the socket, not the file it is bound to.
    ///
    /// - Returns: The file's identity, or `nil` if it cannot be looked up.
    static func fileIdentity(ofDescriptor descriptor: Int32) -> UnixFileIdentity? {
      UnixFileIdentity { fstat(descriptor, &$0) }
    }

    // MARK: - Sockets

    /// Creates a nonblocking, close-on-exec Unix-domain datagram socket that raises no `SIGPIPE`.
    static func makeDatagramSocket() throws -> UnixDescriptor {
      #if canImport(Darwin)
        // Darwin cannot set these as it creates the socket, so they follow at once. A fork on
        // another thread in between would hand the child this descriptor for as long as it runs.
        // A new socket has no other flags to keep, so each is set rather than added.
        let descriptor = try UnixDescriptor(socket(AF_UNIX, SOCK_DGRAM, 0), from: "socket")
        var enabled: Int32 = 1
        // Darwin refuses a datagram larger than the sender's send buffer with `EMSGSIZE`, and that
        // buffer starts at 2 KiB, so it is raised past the longest datagram any endpoint accepts.
        var sendBufferByteCount: Int32 = 65_536
        let size = socklen_t(MemoryLayout<Int32>.size)
        guard
          fcntl(descriptor.rawValue, F_SETFL, O_NONBLOCK) == 0,
          fcntl(descriptor.rawValue, F_SETFD, FD_CLOEXEC) == 0,
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

  /// Which file a path or descriptor refers to: its device and inode, which no two files that
  /// exist at the same time share.
  ///
  /// A path can come to name a different file at any moment, when another process unlinks or
  /// renames over it, so comparing identities is how a caller tells whether the file it holds is
  /// still the one at the path.
  struct UnixFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    /// Reads the identity `lookUp` fills in, or fails if `lookUp` does not return 0.
    fileprivate init?(_ lookUp: (inout stat) -> Int32) {
      var status = stat()
      guard lookUp(&status) == 0 else { return nil }
      // Each C library gives `dev_t` and `ino_t` a width and signedness of its own.
      self.device = UInt64(truncatingIfNeeded: status.st_dev)
      self.inode = UInt64(truncatingIfNeeded: status.st_ino)
    }
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
