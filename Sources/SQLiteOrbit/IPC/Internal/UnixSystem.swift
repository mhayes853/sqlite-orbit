// Every call the IPC transport makes into the platform's C library goes through this file, which is
// the only one in the transport that imports Darwin, Glibc, Musl or Android. How a constant is
// spelled, which flags a call can take, and which readiness queue a thread blocks on are settled
// here, so the rest of the transport needs no guard beyond the one that says it exists at all.
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

  /// A failed system call, named by what it was doing, and the `errno` it failed with.
  struct OrbitIPCSystemError: Error, CustomStringConvertible, Sendable {
    let operation: String
    let code: Int32

    var description: String {
      "\(self.operation) failed with errno \(self.code)"
    }

    /// The error the calling thread's last failed system call left behind.
    static func last(_ operation: String) -> Self {
      Self(operation: operation, code: errno)
    }

    static func invalidArgument(_ operation: String) -> Self {
      Self(operation: operation, code: EINVAL)
    }

    static func closed(_ operation: String) -> Self {
      Self(operation: operation, code: EBADF)
    }

    static func messageTooLong(_ operation: String) -> Self {
      Self(operation: operation, code: EMSGSIZE)
    }

    /// Whether this says the peer a datagram was for is gone.
    ///
    /// A path with nothing behind it fails a connect with `ENOENT`, and one whose socket nobody
    /// holds any more with `ECONNREFUSED`. A socket connected to a peer that then closes gets
    /// `ECONNREFUSED` on Linux and `ECONNRESET` on Darwin, and `ENOTCONN` on either once the
    /// kernel has disconnected it.
    var isStalePeer: Bool {
      [ENOENT, ECONNREFUSED, ECONNRESET, ENOTCONN].contains(self.code)
    }
  }

  enum UnixSystem {
    static func closeDescriptor(_ descriptor: Int32) {
      _ = close(descriptor)
    }

    static func removeFile(atPath path: String) {
      _ = path.withCString { unlink($0) }
    }

    /// Creates an empty file at `path`, or leaves the one already there alone.
    static func createFileIfAbsent(atPath path: String) throws {
      let descriptor = path.withCString {
        open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
      }
      guard descriptor >= 0 else {
        let code = errno
        guard code == EEXIST else { throw OrbitIPCSystemError(operation: "open", code: code) }
        return
      }
      _ = close(descriptor)
    }

    /// Runs `body` holding an exclusive `flock` on the file at `path`, creating the file if needed.
    ///
    /// The lock belongs to the open file, so the kernel lets go of it when this process dies.
    static func withExclusiveFileLock<Result>(
      atPath path: String,
      _ body: () throws -> Result
    ) throws -> Result {
      let descriptor = path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o666) }
      guard descriptor >= 0 else { throw OrbitIPCSystemError.last("open") }
      defer { _ = close(descriptor) }
      while flock(descriptor, LOCK_EX) != 0 {
        let code = errno
        guard code == EINTR else { throw OrbitIPCSystemError(operation: "flock", code: code) }
      }
      return try body()
    }

    /// Creates a nonblocking datagram socket bound to `path`, the address peers send to.
    static func makeBoundDatagramSocket(
      path: String,
      receiveBufferByteCount: Int
    ) throws -> Int32 {
      let descriptor = try makeDatagramSocket()
      do {
        var byteCount = Int32(clamping: receiveBufferByteCount)
        let result = setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_RCVBUF,
          &byteCount,
          socklen_t(MemoryLayout<Int32>.size)
        )
        guard result == 0 else { throw OrbitIPCSystemError.last("setsockopt") }
        var address = try UnixSocketAddress(path: path)
        guard address.withSockAddr({ bind(descriptor, $0, $1) }) == 0 else {
          throw OrbitIPCSystemError.last("bind")
        }
      } catch {
        _ = close(descriptor)
        throw error
      }
      return descriptor
    }

    /// Creates an unbound, nonblocking datagram socket connected to the one bound at `path`.
    ///
    /// Sending on it needs no address, and on Linux it reports itself unwritable while the peer's
    /// receive queue is full, which is what ``UnixEventQueue/reportsPeerWritability`` rests on.
    ///
    /// - Throws: An ``OrbitIPCSystemError`` whose ``OrbitIPCSystemError/isStalePeer`` holds when
    ///   nothing is bound at `path` any more.
    static func makeConnectedDatagramSocket(path: String) throws -> Int32 {
      let descriptor = try makeDatagramSocket()
      var address: UnixSocketAddress
      do {
        address = try UnixSocketAddress(path: path)
      } catch {
        _ = close(descriptor)
        throw error
      }
      guard address.withSockAddr({ connect(descriptor, $0, $1) }) == 0 else {
        let error = OrbitIPCSystemError.last("connect")
        _ = close(descriptor)
        throw error
      }
      return descriptor
    }

    /// Sends one datagram on a connected socket.
    ///
    /// - Returns: `false` when the peer's receive queue is full, which Linux reports as `EAGAIN`
    ///   and Darwin as `ENOBUFS`. Both mean the same thing here: nothing is wrong, and the datagram
    ///   can be sent again once the peer drains.
    static func sendDatagram(
      _ bytes: UnsafeRawBufferPointer,
      on descriptor: Int32
    ) throws -> Bool {
      // Nothing here retries `EINTR`: the socket is nonblocking, so neither this nor `recv` below
      // ever waits in the kernel long enough for a signal to interrupt it.
      let count = send(descriptor, bytes.baseAddress, bytes.count, sendFlags)
      if count == bytes.count { return true }
      guard count < 0 else { throw OrbitIPCSystemError.messageTooLong("send") }
      let code = errno
      if code == EAGAIN || code == EWOULDBLOCK || code == ENOBUFS { return false }
      throw OrbitIPCSystemError(operation: "send", code: code)
    }

    /// Receives one datagram into `buffer`.
    ///
    /// - Returns: The datagram's length, or `nil` once the queue is empty or the socket fails. A
    ///   datagram longer than `buffer` is cut short, so a caller that makes `buffer` one byte
    ///   longer than it accepts can tell one that was too long by its length.
    static func receiveDatagram(
      into buffer: UnsafeMutableRawBufferPointer,
      from descriptor: Int32
    ) -> Int? {
      let count = recv(descriptor, buffer.baseAddress, buffer.count, 0)
      return count >= 0 ? count : nil
    }

    private static func makeDatagramSocket() throws -> Int32 {
      #if canImport(Darwin)
        // Darwin cannot set these as it creates the socket, so they follow at once. A fork on
        // another thread in between would hand the child this descriptor for as long as it runs.
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw OrbitIPCSystemError.last("socket") }
        var enabled: Int32 = 1
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
          fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
          setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
          ) == 0
        else {
          let error = OrbitIPCSystemError.last("configuring a socket")
          _ = close(descriptor)
          throw error
        }
        return descriptor
      #else
        let descriptor = socket(AF_UNIX, socketType, 0)
        guard descriptor >= 0 else { throw OrbitIPCSystemError.last("socket") }
        return descriptor
      #endif
    }

    #if canImport(Darwin)
      // Darwin raises no `SIGPIPE` from these sockets, because each is made with `SO_NOSIGPIPE`.
      private static let sendFlags: Int32 = 0
    #elseif canImport(Glibc)
      // Glibc spells a socket type as a member of an enumeration, where Musl and Bionic spell it
      // as a plain integer macro.
      private static let socketType =
        Int32(SOCK_DGRAM.rawValue) | Int32(SOCK_NONBLOCK.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
      private static let sendFlags = Int32(MSG_NOSIGNAL)
    #else
      private static let socketType =
        Int32(SOCK_DGRAM) | Int32(SOCK_NONBLOCK) | Int32(SOCK_CLOEXEC)
      private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif
  }

  /// The platform's readiness queue, which the transport's thread blocks on.
  ///
  /// It is epoll with an eventfd to wake it on Linux and Android, and kqueue with a user event on
  /// Darwin. Only ``wake()`` may be called from any thread; everything else belongs to the thread
  /// that waits.
  final class UnixEventQueue: @unchecked Sendable {
    /// Something the queue saw become ready.
    enum Event {
      /// The socket the queue was created to read from has a datagram waiting.
      case readable

      /// A socket watched by ``watchWritability(of:token:)`` has room to send.
      case writable(token: UInt64)
    }

    /// Whether a connected socket reports itself writable only while its peer has room.
    ///
    /// Linux holds back a connected datagram socket's writability while the peer's receive queue
    /// is full. Darwin's write filter looks only at the sender's own buffer, which a Unix datagram
    /// never waits in, so a sender there has to retry on a timer instead.
    #if canImport(Darwin)
      static let reportsPeerWritability = false
    #else
      static let reportsPeerWritability = true
    #endif

    private let descriptor: Int32
    #if canImport(Darwin)
      private let events = UnsafeMutableBufferPointer<kevent>.allocate(capacity: 64)
    #else
      private let wakeDescriptor: Int32
      private let events = UnsafeMutableRawBufferPointer.allocate(
        byteCount: 64 * epollEventByteCount,
        alignment: 8
      )
    #endif

    /// Creates a queue that reports when `socket` has a datagram to read.
    ///
    /// The queue does not own `socket`, which must outlive it.
    init(readingFrom socket: Int32) throws {
      #if canImport(Darwin)
        let descriptor = kqueue()
        guard descriptor >= 0 else { throw OrbitIPCSystemError.last("kqueue") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var changes = [
          kevent(
            ident: UInt(socket),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD),
            fflags: 0,
            data: 0,
            udata: nil
          ),
          kevent(
            ident: Self.wakeIdentifier,
            filter: Int16(EVFILT_USER),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: 0,
            data: 0,
            udata: nil
          )
        ]
        guard Darwin.kevent(descriptor, &changes, Int32(changes.count), nil, 0, nil) == 0 else {
          let error = OrbitIPCSystemError.last("kevent")
          _ = close(descriptor)
          throw error
        }
        self.descriptor = descriptor
      #else
        // `EPOLL_CLOEXEC`, `EFD_CLOEXEC` and `EFD_NONBLOCK` are defined as the `O_` flags.
        let descriptor = epollCreate(Int32(O_CLOEXEC))
        guard descriptor >= 0 else { throw OrbitIPCSystemError.last("epoll_create1") }
        let wakeDescriptor = eventFileDescriptor(0, Int32(O_NONBLOCK | O_CLOEXEC))
        guard wakeDescriptor >= 0 else {
          let error = OrbitIPCSystemError.last("eventfd")
          _ = close(descriptor)
          throw error
        }
        guard Self.control(descriptor, Self.add, socket, Self.readable, Self.readableToken),
          Self.control(descriptor, Self.add, wakeDescriptor, Self.readable, Self.wakeToken)
        else {
          let error = OrbitIPCSystemError.last("epoll_ctl")
          _ = close(wakeDescriptor)
          _ = close(descriptor)
          throw error
        }
        self.descriptor = descriptor
        self.wakeDescriptor = wakeDescriptor
      #endif
    }

    deinit {
      #if !canImport(Darwin)
        _ = close(self.wakeDescriptor)
      #endif
      _ = close(self.descriptor)
      self.events.deallocate()
    }

    /// Ends the current or next ``wait(until:_:)`` early. Safe to call from any thread.
    func wake() {
      #if canImport(Darwin)
        var change = kevent(
          ident: Self.wakeIdentifier,
          filter: Int16(EVFILT_USER),
          flags: 0,
          fflags: UInt32(NOTE_TRIGGER),
          data: 0,
          udata: nil
        )
        _ = Darwin.kevent(self.descriptor, &change, 1, nil, 0, nil)
      #else
        // A full counter would fail this with `EAGAIN`, and a full counter already wakes the queue.
        var increment: UInt64 = 1
        _ = write(self.wakeDescriptor, &increment, MemoryLayout<UInt64>.size)
      #endif
    }

    /// Blocks until something is ready, the queue is woken, or `deadline` passes, then hands every
    /// ready event to `handle`.
    ///
    /// - Parameters:
    ///   - deadline: When to stop waiting, or `nil` to wait for as long as it takes.
    ///   - handle: Receives each event that was ready.
    func wait(until deadline: ContinuousClock.Instant?, _ handle: (Event) -> Void) {
      let timeout = deadline.map { max(.zero, $0 - .now) }
      #if canImport(Darwin)
        let count: Int32
        if let timeout {
          let (seconds, attoseconds) = timeout.components
          var interval = timespec(
            tv_sec: Int(seconds),
            tv_nsec: Int(attoseconds / 1_000_000_000)
          )
          count = Darwin.kevent(
            self.descriptor,
            nil,
            0,
            self.events.baseAddress,
            Int32(self.events.count),
            &interval
          )
        } else {
          count = Darwin.kevent(
            self.descriptor,
            nil,
            0,
            self.events.baseAddress,
            Int32(self.events.count),
            nil
          )
        }
        Self.check(count, "kevent")
        for event in self.events.prefix(max(0, Int(count)))
        where event.filter == Int16(EVFILT_READ) {
          handle(.readable)
        }
      #else
        // Rounded up, so a wait never ends just short of its deadline and spins until it passes.
        let milliseconds = timeout.map { timeout -> Int32 in
          let (seconds, attoseconds) = timeout.components
          let total = seconds * 1_000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
          return Int32(clamping: total)
        }
        let count = epollWait(
          self.descriptor,
          self.events.baseAddress,
          Int32(self.events.count / epollEventByteCount),
          milliseconds ?? -1
        )
        Self.check(count, "epoll_wait")
        for index in 0..<max(0, Int(count)) {
          let token = self.events.loadUnaligned(
            fromByteOffset: index * epollEventByteCount + epollEventDataOffset,
            as: UInt64.self
          )
          switch token {
          case Self.readableToken:
            handle(.readable)
          case Self.wakeToken:
            var counter: UInt64 = 0
            _ = read(self.wakeDescriptor, &counter, MemoryLayout<UInt64>.size)
          case let token:
            handle(.writable(token: token))
          }
        }
      #endif
    }

    // A signal that interrupts the wait only ends it early. Any other failure means a descriptor
    // this queue owns is gone, which nothing here can recover from.
    private static func check(_ count: Int32, _ operation: String) {
      guard count < 0 else { return }
      let code = errno
      precondition(code == EINTR, "\(operation) failed with errno \(code)")
    }

    #if canImport(Darwin)
      private static let wakeIdentifier: UInt = 1
    #else
      /// Starts reporting ``Event/writable(token:)`` for `descriptor` whenever it has room to send.
      ///
      /// - Parameters:
      ///   - descriptor: A connected socket. Stop watching it before closing it.
      ///   - token: What the events for it carry, which must be ``firstWatchToken`` or greater.
      func watchWritability(of descriptor: Int32, token: UInt64) throws {
        precondition(token >= Self.firstWatchToken)
        guard Self.control(self.descriptor, Self.add, descriptor, Self.writable, token) else {
          throw OrbitIPCSystemError.last("epoll_ctl")
        }
      }

      /// Stops reporting writability for `descriptor`.
      func stopWatchingWritability(of descriptor: Int32) {
        _ = Self.control(self.descriptor, Self.delete, descriptor, 0, 0)
      }

      /// The smallest token ``watchWritability(of:token:)`` accepts.
      static let firstWatchToken: UInt64 = 2

      private static let readableToken: UInt64 = 0
      private static let wakeToken: UInt64 = 1

      // The kernel's own values, which every Linux architecture shares.
      private static let readable: UInt32 = 0x001
      private static let writable: UInt32 = 0x004
      private static let add: Int32 = 1
      private static let delete: Int32 = 2

      private static func control(
        _ queue: Int32,
        _ operation: Int32,
        _ descriptor: Int32,
        _ events: UInt32,
        _ token: UInt64
      ) -> Bool {
        withUnsafeTemporaryAllocation(byteCount: epollEventByteCount, alignment: 8) { event in
          event.storeBytes(of: events, toByteOffset: 0, as: UInt32.self)
          event.storeBytes(of: token, toByteOffset: epollEventDataOffset, as: UInt64.self)
          return epollControl(queue, operation, descriptor, event.baseAddress) == 0
        }
      }
    #endif
  }

  #if !canImport(Darwin)
    // Swift's Glibc and Musl modules leave out `sys/epoll.h` and `sys/eventfd.h`, so the calls are
    // declared here, and an event is read and written as the bytes the kernel lays it out as: a
    // 32-bit mask followed by 64 bits of data, packed together on x86 and aligned elsewhere.
    @_extern(c, "epoll_create1")
    private func epollCreate(_ flags: Int32) -> Int32

    @_extern(c, "epoll_ctl")
    private func epollControl(
      _ queue: Int32,
      _ operation: Int32,
      _ descriptor: Int32,
      _ event: UnsafeMutableRawPointer?
    ) -> Int32

    @_extern(c, "epoll_wait")
    private func epollWait(
      _ queue: Int32,
      _ events: UnsafeMutableRawPointer?,
      _ capacity: Int32,
      _ timeout: Int32
    ) -> Int32

    @_extern(c, "eventfd")
    private func eventFileDescriptor(_ value: UInt32, _ flags: Int32) -> Int32

    #if arch(x86_64) || arch(i386)
      private let epollEventByteCount = 12
      private let epollEventDataOffset = 4
    #else
      private let epollEventByteCount = 16
      private let epollEventDataOffset = 8
    #endif
  #endif

  private struct UnixSocketAddress {
    private var storage: sockaddr_un
    private let length: socklen_t

    init(path: String) throws {
      guard !path.utf8.contains(0) else {
        throw OrbitIPCSystemError.invalidArgument("socket path contains NUL")
      }

      var storage = sockaddr_un()
      storage.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.utf8) + [0]
      guard bytes.count <= MemoryLayout.size(ofValue: storage.sun_path) else {
        throw OrbitIPCSystemError(operation: "socket path is too long", code: ENAMETOOLONG)
      }
      withUnsafeMutableBytes(of: &storage.sun_path) { destination in
        destination.copyBytes(from: bytes)
      }
      let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
      let length = socklen_t(offset + bytes.count)
      #if canImport(Darwin)
        storage.sun_len = UInt8(length)
      #endif
      self.storage = storage
      self.length = length
    }

    mutating func withSockAddr<Result>(
      _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) rethrows -> Result {
      try withUnsafePointer(to: &self.storage) { storage in
        try storage.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          try body($0, self.length)
        }
      }
    }
  }
#endif
