#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  @Suite
  final class UnixSystemTests {
    let directory: URL

    init() throws {
      self.directory = try makeShortTemporaryDirectory("system")
    }

    deinit {
      try? FileManager.default.removeItem(at: self.directory)
    }

    @Test
    func bindsUnderAHiddenNameAndRenamesIntoPlace() throws {
      let path = directory.appending(path: "a.sock").path
      #expect(
        UnixDatagramSocket.temporaryPath(binding: path)
          == directory.appending(path: ".a.sock").path
      )
      #expect(UnixDatagramSocket.temporaryPath(binding: "a.sock") == ".a.sock")

      let socket = try Self.bind(path)
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["a.sock"])
      #expect(socket.boundFile != nil)
      #expect(socket.boundFile == UnixPlatform.fileIdentity(atPath: path))
    }

    @Test
    func bindReplacesWhateverIsAtThePath() throws {
      let path = directory.appending(path: "a.sock").path
      try Self.bindAndClose(path)
      #expect(UnixDatagramSocket.probe(path) == .dead)

      let socket = try Self.bind(path)
      #expect(UnixDatagramSocket.probe(path) == .alive)
      #expect(socket.boundFile == UnixPlatform.fileIdentity(atPath: path))
    }

    @Test
    func bindLeavesNothingBehindWhenItFails() throws {
      // Renaming a socket over a directory fails.
      let path = directory.appending(path: "a.sock", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)

      #expect(throws: UnixSystemError.self) {
        _ = try Self.bind(path.path)
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["a.sock"])
    }

    @Test
    func probesWhetherASocketIsBoundAtAPath() throws {
      let path = directory.appending(path: "a.sock").path

      #expect(UnixDatagramSocket.probe(path) == .dead)

      let socket = try Self.bind(path)
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
      let file = directory.appending(path: "file").path
      #expect(FileManager.default.createFile(atPath: file, contents: nil))
      let socketPath = directory.appending(path: "a.sock").path
      let socket = try Self.bind(socketPath)

      let past = Date(timeIntervalSinceNow: -10 * 24 * 60 * 60)
      for path in [file, socketPath] {
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)
        #expect(try Self.modificationDate(path) < Date(timeIntervalSinceNow: -60))

        #expect(FileSystem.touchFile(atPath: path))
        #expect(try Self.modificationDate(path) > Date(timeIntervalSinceNow: -60))
      }
      #expect(UnixDatagramSocket.probe(socketPath) == .alive)
      _ = socket.boundFile

      #expect(!FileSystem.touchFile(atPath: directory.appending(path: "missing").path))
    }

    @Test
    func removesADirectoryOnlyIfItIsEmpty() throws {
      let child = directory.appending(path: "child", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
      let file = child.appending(path: "f")
      #expect(FileManager.default.createFile(atPath: file.path, contents: nil))

      #expect(!FileSystem.removeDirectory(atPath: child.path))
      #expect(
        [UnixPlatform.ErrorCode.notEmpty, UnixPlatform.ErrorCode.fileExists]
          .contains(UnixPlatform.lastErrorCode)
      )

      try FileManager.default.removeItem(at: file)
      #expect(FileSystem.removeDirectory(atPath: child.path))
      #expect(!FileManager.default.fileExists(atPath: child.path))

      #expect(!FileSystem.removeDirectory(atPath: child.path))
      #expect(UnixPlatform.lastErrorCode == UnixPlatform.ErrorCode.noSuchFile)
    }

    @Test
    func createsADirectoryAndEveryMissingOneAboveIt() throws {
      let nested = directory.appending(path: "a/b/c").path
      try FileSystem.createDirectory(atPath: nested)
      var isDirectory: ObjCBool = false
      #expect(FileManager.default.fileExists(atPath: nested, isDirectory: &isDirectory))
      #expect(isDirectory.boolValue)

      // Already there, with a trailing slash or without.
      try FileSystem.createDirectory(atPath: nested)
      try FileSystem.createDirectory(atPath: nested + "/")

      let file = directory.appending(path: "file").path
      #expect(FileManager.default.createFile(atPath: file, contents: nil))
      #expect(throws: UnixSystemError(operation: "mkdir", code: UnixPlatform.ErrorCode.fileExists))
      {
        try FileSystem.createDirectory(atPath: file)
      }
      #expect(throws: UnixSystemError.self) {
        try FileSystem.createDirectory(atPath: file + "/below")
      }
    }

    @Test
    func listsWhatIsInADirectory() throws {
      for name in ["a", ".hidden", "é"] {
        #expect(
          FileManager.default.createFile(
            atPath: directory.appending(path: name).path,
            contents: nil
          )
        )
      }
      try FileManager.default.createDirectory(
        at: directory.appending(path: "child"),
        withIntermediateDirectories: false
      )

      let names = try FileSystem.contentsOfDirectory(atPath: directory.path)
      #expect(names.sorted() == ["a", ".hidden", "é", "child"].sorted())
      #expect(
        names.sorted()
          == (try FileManager.default.contentsOfDirectory(atPath: directory.path)).sorted()
      )
      #expect(
        throws: UnixSystemError(operation: "opendir", code: UnixPlatform.ErrorCode.noSuchFile)
      ) {
        try FileSystem.contentsOfDirectory(atPath: directory.appending(path: "missing").path)
      }
    }

    @Test
    func writesAndReadsAFileWhole() throws {
      let path = directory.appending(path: "file").path
      #expect(
        throws: UnixSystemError(operation: "open", code: UnixPlatform.ErrorCode.noSuchFile)
      ) {
        try FileSystem.contentsOfFile(atPath: path)
      }

      let large = (0..<10_000).map { UInt8(truncatingIfNeeded: $0) }
      try FileSystem.writeFile(large, atPath: path)
      #expect(try FileSystem.contentsOfFile(atPath: path) == large)
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(large))

      // Replaced in place, and cut short rather than overwritten.
      try FileSystem.writeFile([1, 2, 3], atPath: path)
      #expect(try FileSystem.contentsOfFile(atPath: path) == [1, 2, 3])
      try FileSystem.writeFile([], atPath: path)
      #expect(try FileSystem.contentsOfFile(atPath: path) == [])

      #expect(
        throws: UnixSystemError(operation: "open", code: UnixPlatform.ErrorCode.noSuchFile)
      ) {
        try FileSystem.writeFile([1], atPath: directory.appending(path: "missing/file").path)
      }
    }

    @Test
    func agesAFileByItsModificationTime() throws {
      let path = directory.appending(path: "file").path
      #expect(FileSystem.ageOfFile(atPath: path) == nil)

      #expect(FileManager.default.createFile(atPath: path, contents: nil))
      let age = try #require(FileSystem.ageOfFile(atPath: path))
      #expect(age >= .seconds(-1) && age < .seconds(60))

      try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(-3_600)],
        ofItemAtPath: path
      )
      let older = try #require(FileSystem.ageOfFile(atPath: path))
      #expect(older >= .seconds(3_599) && older < .seconds(3_660))
    }

    @Test
    func identifiesTheFileAtAPath() throws {
      let path = directory.appending(path: "file").path
      #expect(UnixPlatform.fileIdentity(atPath: path) == nil)

      #expect(FileManager.default.createFile(atPath: path, contents: nil))
      let first = try #require(UnixPlatform.fileIdentity(atPath: path))
      #expect(UnixPlatform.fileIdentity(atPath: path) == first)

      // Another file is created before the first is removed, so the two cannot share an inode.
      let other = directory.appending(path: "other").path
      #expect(FileManager.default.createFile(atPath: other, contents: nil))
      #expect(FileSystem.renameFile(atPath: other, toPath: path))
      #expect(UnixPlatform.fileIdentity(atPath: path) != first)
    }

    @Test
    func aDirectoryWatcherWakesAnEventQueueWaitingOnIt() throws {
      let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: false)
      let file = watched.appending(path: "file")
      #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
      let watcher = try UnixDirectoryWatcher()
      try watcher.watch(watched.path)
      let queue = try UnixEventQueue()
      try queue.watchReadable(watcher.descriptor)

      #expect(Self.readableDescriptors(queue, within: .milliseconds(20)).isEmpty)

      try FileManager.default.removeItem(at: file)
      #expect(Self.readableDescriptors(queue, within: .seconds(5)) == [watcher.descriptor])
      #expect(watcher.drainChanges())
      #expect(Self.readableDescriptors(queue, within: .milliseconds(20)).isEmpty)

      #expect(FileSystem.removeDirectory(atPath: watched.path))
      #expect(Self.readableDescriptors(queue, within: .seconds(5)) == [watcher.descriptor])
      #expect(watcher.drainChanges())
    }

    /// Waits on `queue` until something is readable or `timeout` passes.
    ///
    /// - Returns: The descriptors reported readable.
    private static func readableDescriptors(
      _ queue: UnixEventQueue,
      within timeout: Duration
    ) -> [Int32] {
      let deadline = ContinuousClock.now + timeout
      var descriptors: [Int32] = []
      // A signal can end a wait early, with nothing to report.
      while descriptors.isEmpty, ContinuousClock.now < deadline {
        queue.wait(until: deadline) { event in
          if case .readable(let descriptor) = event { descriptors.append(descriptor) }
        }
      }
      return descriptors
    }

    private static func bind(_ path: String) throws -> UnixDatagramSocket {
      try UnixDatagramSocket.bind(path: path, receiveBufferByteCount: 64 * 1024)
    }

    /// Binds a socket at `path` and closes it, leaving its file behind as a process that died
    /// would.
    private static func bindAndClose(_ path: String) throws {
      _ = try Self.bind(path).boundFile
    }

    private static func modificationDate(_ path: String) throws -> Date {
      try #require(
        FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
      )
    }
  }
#endif
