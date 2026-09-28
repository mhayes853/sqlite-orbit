#if canImport(Darwin) || os(Linux) || os(Android)
  import Dispatch
  import Foundation
  import Synchronization
  import Testing

  @testable import SQLiteOrbit

  @Suite
  struct UnixFileLockTests {
    @Test
    func removesTheLockFileOnceLetGoOf() throws {
      let directory = try makeShortTemporaryDirectory("flock")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "a.lock").path

      let existedWhileHeld = try UnixFileLock.withExclusiveLock(atPath: path) {
        FileManager.default.fileExists(atPath: path)
      }
      #expect(existedWhileHeld)
      #expect(!FileManager.default.fileExists(atPath: path))

      #expect(throws: CancellationError.self) {
        try UnixFileLock.withExclusiveLock(atPath: path) { throw CancellationError() }
      }
      #expect(!FileManager.default.fileExists(atPath: path))

      #expect(try UnixFileLock.withExclusiveLockIfAvailable(atPath: path) { 1 } == 1)
      #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func openLockLeavesNoLockFilesBehind() throws {
      let directory = try makeShortTemporaryDirectory("flock")
      defer { try? FileManager.default.removeItem(at: directory) }

      for name in ["one", "two"] {
        try OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: OrbitDatabaseIdentifier(rawValue: name),
          directory: directory
        ) {}
      }
      let locks = directory.appending(path: "open-locks").path
      #expect(try FileManager.default.contentsOfDirectory(atPath: locks).isEmpty)
    }

    @Test
    func excludesEveryOtherHolderWhileFilesAreUnlinkedAndCreatedAgain() throws {
      let directory = try makeShortTemporaryDirectory("flock")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "a.lock").path
      let state = ExclusionState()
      let threadCount = 6
      let iterationCount = 300

      DispatchQueue.concurrentPerform(iterations: threadCount) { index in
        for iteration in 0..<iterationCount {
          // Some holders only try, so the nonblocking path races the unlinking too.
          let body = { state.enter() }
          if (index + iteration).isMultiple(of: 3) {
            while (try? UnixFileLock.withExclusiveLockIfAvailable(atPath: path, body)) == nil {}
          } else {
            try? UnixFileLock.withExclusiveLock(atPath: path, body)
          }
        }
      }

      #expect(state.overlaps.load(ordering: .relaxed) == 0)
      #expect(state.count == threadCount * iterationCount)
      #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func skipsTheBodyWhileAnotherHolderHasTheLock() throws {
      let directory = try makeShortTemporaryDirectory("flock")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "a.lock").path

      let holder = FileLockHolder(path)
      var didRun = false
      #expect(try UnixFileLock.withExclusiveLockIfAvailable(atPath: path) { didRun = true } == nil)
      #expect(!didRun)
      holder.release()

      #expect(try UnixFileLock.withExclusiveLockIfAvailable(atPath: path) { didRun = true } != nil)
      #expect(didRun)
    }

    @Test
    func removesOnlyALockFileNobodyHolds() throws {
      let directory = try makeShortTemporaryDirectory("flock")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "a.lock").path

      #expect(!UnixFileLock.removeIfUnlocked(atPath: path))

      let holder = FileLockHolder(path)
      #expect(!UnixFileLock.removeIfUnlocked(atPath: path))
      #expect(FileManager.default.fileExists(atPath: path))
      holder.release()

      // What a process that died holding the lock leaves behind.
      #expect(FileManager.default.createFile(atPath: path, contents: nil))
      #expect(UnixFileLock.removeIfUnlocked(atPath: path))
      #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func openLockRemovesTheLocksNobodyHolds() throws {
      let directory = try makeShortTemporaryDirectory("flock")
      defer { try? FileManager.default.removeItem(at: directory) }
      let locks = directory.appending(path: "open-locks", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
      for name in ["left.lock", "behind.lock"] {
        let path = locks.appending(path: name).path
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
      }
      let holder = FileLockHolder(locks.appending(path: "held.lock").path)
      defer { holder.release() }

      #expect(OrbitDatabaseOpenLock.removeUnheldLocks(directory: directory) == 2)
      #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path) == ["held.lock"])
    }
  }

  /// Counts holders of a lock, with a count only the lock protects and a tally of the times a
  /// holder found another already inside.
  private final class ExclusionState: @unchecked Sendable {
    let overlaps = Atomic(0)
    private let inside = Atomic(0)
    private(set) var count = 0

    func enter() {
      if self.inside.add(1, ordering: .relaxed).newValue != 1 {
        self.overlaps.add(1, ordering: .relaxed)
      }
      // A read and a write apart, so two holders at once would lose an increment.
      let count = self.count
      for _ in 0..<50 { _ = self.inside.load(ordering: .relaxed) }
      self.count = count + 1
      self.inside.subtract(1, ordering: .relaxed)
    }
  }

  /// Holds a file lock on a thread of its own until released.
  private final class FileLockHolder: Sendable {
    private let acquired = DispatchSemaphore(value: 0)
    private let mayRelease = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    init(_ path: String) {
      Thread.detachNewThread {
        try? UnixFileLock.withExclusiveLock(atPath: path) {
          self.acquired.signal()
          self.mayRelease.wait()
        }
        self.released.signal()
      }
      self.acquired.wait()
    }

    func release() {
      self.mayRelease.signal()
      self.released.wait()
    }
  }
#endif
