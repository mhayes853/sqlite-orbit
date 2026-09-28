#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct UnixSystemTests {
    @Test
    func bindsUnderAHiddenNameAndRenamesIntoPlace() throws {
      let directory = try makeShortTemporaryDirectory("system")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "a.sock").path
      #expect(
        UnixDatagramSocket.temporaryPath(binding: path)
          == directory.appending(path: ".a.sock").path
      )
      #expect(UnixDatagramSocket.temporaryPath(binding: "a.sock") == ".a.sock")

      let socket = try UnixDatagramSocket.bind(path: path, receiveBufferByteCount: 64 * 1024)
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["a.sock"])
      #expect(socket.boundFile != nil)
      #expect(socket.boundFile == UnixPlatform.fileIdentity(atPath: path))
    }

    @Test
    func bindReplacesWhateverIsAtThePath() throws {
      let directory = try makeShortTemporaryDirectory("system")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "a.sock").path
      try Self.bindAndClose(path)
      #expect(UnixDatagramSocket.probe(path) == .dead)

      let socket = try UnixDatagramSocket.bind(path: path, receiveBufferByteCount: 64 * 1024)
      #expect(UnixDatagramSocket.probe(path) == .alive)
      #expect(socket.boundFile == UnixPlatform.fileIdentity(atPath: path))
    }

    @Test
    func bindLeavesNothingBehindWhenItFails() throws {
      let directory = try makeShortTemporaryDirectory("system")
      defer { try? FileManager.default.removeItem(at: directory) }
      // Renaming a socket over a directory fails.
      let path = directory.appending(path: "a.sock", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)

      #expect(throws: UnixSystemError.self) {
        try UnixDatagramSocket.bind(path: path.path, receiveBufferByteCount: 64 * 1024)
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["a.sock"])
    }

    @Test
    func probesWhetherASocketIsBoundAtAPath() throws {
      let directory = try makeShortTemporaryDirectory("system")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "a.sock").path

      #expect(UnixDatagramSocket.probe(path) == .dead)

      let socket = try UnixDatagramSocket.bind(path: path, receiveBufferByteCount: 64 * 1024)
      #expect(UnixDatagramSocket.probe(path) == .alive)
      // A probe sends nothing.
      var buffer = [UInt8](repeating: 0, count: 16)
      #expect(buffer.withUnsafeMutableBufferPointer { socket.receive(into: $0) } == nil)

      let closedPath = directory.appending(path: "b.sock").path
      try Self.bindAndClose(closedPath)
      #expect(FileManager.default.fileExists(atPath: closedPath))
      #expect(UnixDatagramSocket.probe(closedPath) == .dead)
    }

    @Test
    func touchingAFileMakesItsTimesNow() throws {
      let directory = try makeShortTemporaryDirectory("system")
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appending(path: "file").path
      #expect(FileManager.default.createFile(atPath: file, contents: nil))
      let socketPath = directory.appending(path: "a.sock").path
      let socket = try UnixDatagramSocket.bind(path: socketPath, receiveBufferByteCount: 64 * 1024)

      let past = Date(timeIntervalSinceNow: -10 * 24 * 60 * 60)
      for path in [file, socketPath] {
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)
        #expect(try Self.modificationDate(path) < Date(timeIntervalSinceNow: -60))

        #expect(UnixPlatform.touchFile(atPath: path))
        #expect(try Self.modificationDate(path) > Date(timeIntervalSinceNow: -60))
      }
      #expect(UnixDatagramSocket.probe(socketPath) == .alive)
      _ = socket.boundFile

      #expect(!UnixPlatform.touchFile(atPath: directory.appending(path: "missing").path))
    }

    @Test
    func removesADirectoryOnlyIfItIsEmpty() throws {
      let directory = try makeShortTemporaryDirectory("system")
      defer { try? FileManager.default.removeItem(at: directory) }
      let child = directory.appending(path: "child", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
      let file = child.appending(path: "f")
      #expect(FileManager.default.createFile(atPath: file.path, contents: nil))

      #expect(!UnixPlatform.removeDirectory(atPath: child.path))
      #expect(
        [UnixPlatform.ErrorCode.notEmpty, UnixPlatform.ErrorCode.fileExists]
          .contains(UnixPlatform.lastErrorCode)
      )

      try FileManager.default.removeItem(at: file)
      #expect(UnixPlatform.removeDirectory(atPath: child.path))
      #expect(!FileManager.default.fileExists(atPath: child.path))

      #expect(!UnixPlatform.removeDirectory(atPath: child.path))
      #expect(UnixPlatform.lastErrorCode == UnixPlatform.ErrorCode.noSuchFile)
    }

    @Test
    func identifiesTheFileAtAPath() throws {
      let directory = try makeShortTemporaryDirectory("system")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "file").path
      #expect(UnixPlatform.fileIdentity(atPath: path) == nil)

      #expect(FileManager.default.createFile(atPath: path, contents: nil))
      let first = try #require(UnixPlatform.fileIdentity(atPath: path))
      #expect(UnixPlatform.fileIdentity(atPath: path) == first)

      // Another file is created before the first is removed, so the two cannot share an inode.
      let other = directory.appending(path: "other").path
      #expect(FileManager.default.createFile(atPath: other, contents: nil))
      #expect(UnixPlatform.renameFile(atPath: other, toPath: path))
      #expect(UnixPlatform.fileIdentity(atPath: path) != first)
    }

    /// Binds a socket at `path` and closes it, leaving its file behind as a process that died
    /// would.
    private static func bindAndClose(_ path: String) throws {
      let socket = try UnixDatagramSocket.bind(path: path, receiveBufferByteCount: 64 * 1024)
      _ = socket.boundFile
    }

    private static func modificationDate(_ path: String) throws -> Date {
      try #require(
        FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
      )
    }
  }
#endif
