#if canImport(Darwin) || canImport(Glibc)
  import Foundation
  import Synchronization

  #if canImport(Darwin)
    import Darwin
    private let unixDatagramSocketType = SOCK_DGRAM
    private let closeUnixDescriptor = Darwin.close
    private let unlinkUnixPath = Darwin.unlink
  #elseif canImport(Glibc)
    import Glibc
    private let unixDatagramSocketType = Int32(SOCK_DGRAM.rawValue)
    private let closeUnixDescriptor = Glibc.close
    private let unlinkUnixPath = Glibc.unlink
  #endif

  struct UnixSocketAddress {
    private var storage: sockaddr_un
    let length: socklen_t

    init(path: String) throws {
      guard !path.utf8.contains(0) else {
        throw DatabaseIPCSystemError(operation: "socket path contains NUL", code: EINVAL)
      }

      var storage = sockaddr_un()
      storage.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.utf8) + [0]
      guard bytes.count <= MemoryLayout.size(ofValue: storage.sun_path) else {
        throw DatabaseIPCSystemError(operation: "socket path is too long", code: ENAMETOOLONG)
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

  struct DatabaseIPCSystemError: Error, CustomStringConvertible, Sendable {
    let operation: String
    let code: Int32

    var description: String {
      "\(self.operation) failed with errno \(self.code)"
    }
  }

  final class UnixDatagramSocket: Sendable {
    private let storage: Mutex<Storage>

    var descriptor: Int32 {
      self.storage.withLock { $0.descriptor }
    }

    init(path: String, receiveBufferByteCount: Int) throws {
      let descriptor = try Self.makeDescriptor()
      do {
        try Self.configure(descriptor, receiveBufferByteCount: receiveBufferByteCount)
        var address = try UnixSocketAddress(path: path)
        let result = address.withSockAddr {
          bind(descriptor, $0, $1)
        }
        guard result == 0 else {
          throw DatabaseIPCSystemError(operation: "bind", code: errno)
        }
      } catch {
        _ = closeUnixDescriptor(descriptor)
        throw error
      }
      self.storage = Mutex(Storage(descriptor: descriptor, path: path))
    }

    deinit {
      self.close()
    }

    func close() {
      self.storage.withLock { $0.close() }
    }

    func send(_ bytes: [UInt8], to path: String) throws -> Bool {
      try self.storage.withLock { storage in
        guard !storage.isClosed else {
          throw DatabaseIPCSystemError(operation: "sendto", code: EBADF)
        }
        var address = try UnixSocketAddress(path: path)
        let result = bytes.withUnsafeBytes { bytes in
          address.withSockAddr { address, length in
            sendto(
              storage.descriptor,
              bytes.baseAddress,
              bytes.count,
              0,
              address,
              length
            )
          }
        }
        if result == bytes.count { return true }
        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK { return false }
        throw DatabaseIPCSystemError(operation: "sendto", code: code)
      }
    }

    func receive(maximumByteCount: Int) throws -> [UInt8]? {
      try self.storage.withLock { storage in
        guard !storage.isClosed else {
          throw DatabaseIPCSystemError(operation: "recv", code: EBADF)
        }
        var bytes = [UInt8](repeating: 0, count: maximumByteCount + 1)
        let count = bytes.withUnsafeMutableBytes {
          recv(storage.descriptor, $0.baseAddress, $0.count, 0)
        }
        if count >= 0 {
          bytes.removeLast(bytes.count - count)
          return bytes
        }
        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK { return nil }
        throw DatabaseIPCSystemError(operation: "recv", code: code)
      }
    }

    private static func makeDescriptor() throws -> Int32 {
      let descriptor = socket(AF_UNIX, unixDatagramSocketType, 0)
      guard descriptor >= 0 else {
        throw DatabaseIPCSystemError(operation: "socket", code: errno)
      }
      return descriptor
    }

    private static func configure(
      _ descriptor: Int32,
      receiveBufferByteCount: Int
    ) throws {
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw DatabaseIPCSystemError(operation: "fcntl", code: errno)
      }
      let descriptorFlags = fcntl(descriptor, F_GETFD)
      guard descriptorFlags >= 0,
        fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
      else {
        throw DatabaseIPCSystemError(operation: "fcntl", code: errno)
      }
      var receiveBufferByteCount = Int32(clamping: receiveBufferByteCount)
      let receiveBufferValueSize = socklen_t(MemoryLayout.size(ofValue: receiveBufferByteCount))
      let result = withUnsafePointer(to: &receiveBufferByteCount) {
        setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_RCVBUF,
          $0,
          receiveBufferValueSize
        )
      }
      guard result == 0 else {
        throw DatabaseIPCSystemError(operation: "setsockopt", code: errno)
      }
    }

    /// Uniquely owns the descriptor shared by the transport's send and receive paths.
    private struct Storage: ~Copyable {
      let descriptor: Int32
      let path: String
      var isClosed = false

      deinit {
        guard !self.isClosed else { return }
        _ = closeUnixDescriptor(self.descriptor)
        _ = self.path.withCString(unlinkUnixPath)
      }

      mutating func close() {
        guard !self.isClosed else { return }
        self.isClosed = true
        _ = closeUnixDescriptor(self.descriptor)
        _ = self.path.withCString(unlinkUnixPath)
      }
    }
  }
#endif
