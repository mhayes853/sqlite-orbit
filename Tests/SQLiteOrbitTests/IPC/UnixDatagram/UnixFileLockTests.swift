#if canImport(Darwin) || os(Linux) || os(Android)
  import Dispatch
  import Foundation
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
          directory: directory,
          configuration: .default
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
          // Some holders only try, and some try again until they have it, so the paths that do
          // not wait in `flock` race the unlinking too.
          let body = { state.enter() }
          switch (index + iteration) % 3 {
          case 0:
            while (try? UnixFileLock.withExclusiveLockIfAvailable(atPath: path, body)) == nil {}
          case 1:
            _ = try? UnixFileLock.withExclusiveLock(atPath: path, waitingWhile: { _ in true }, body)
          default:
            try? UnixFileLock.withExclusiveLock(atPath: path, body)
          }
        }
      }

      #expect(state.overlaps.withLock { $0 } == 0)
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
    func waitingWhileAsksOnEveryTryThatFindsTheLockHeldAndGivesUpWhenToldTo() async throws {
      let directory = try makeShortTemporaryDirectory("flock")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "a.lock").path
      let holder = FileLockHolder(path)
      defer { holder.release() }

      let (result, attempts) = try await withDeadline {
        var attempts: [Int] = []
        let result = try UnixFileLock.withExclusiveLock(
          atPath: path,
          waitingWhile: { attempt in
            attempts.append(attempt)
            return attempt < 3
          },
          { true }
        )
        return (result, attempts)
      }
      #expect(result == nil)
      #expect(attempts == [1, 2, 3])

      let (gaveUpAtOnce, firstAttempts) = try await withDeadline {
        var attempts: [Int] = []
        let result = try UnixFileLock.withExclusiveLock(
          atPath: path,
          waitingWhile: { attempt in
            attempts.append(attempt)
            return false
          },
          { true }
        )
        return (result, attempts)
      }
      #expect(gaveUpAtOnce == nil)
      #expect(firstAttempts == [1])
      // Still the holder's, and still there.
      #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test
    func waitingWhileTakesTheLockOnceItsHolderLetsGoMidWait() async throws {
      let directory = try makeShortTemporaryDirectory("flock")
      defer { try? FileManager.default.removeItem(at: directory) }
      let path = directory.appending(path: "a.lock").path
      let holder = FileLockHolder(path)

      let (result, lastAttempt) = try await withDeadline {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var lastAttempt = 0
        let result = try UnixFileLock.withExclusiveLock(
          atPath: path,
          waitingWhile: { attempt in
            lastAttempt = attempt
            if attempt == 2 { holder.release() }
            // A process another test is spawning can hold a copy of the holder's descriptor
            // until it execs, so letting go is not always seen on the very next try.
            Thread.sleep(forTimeInterval: 0.001)
            return ContinuousClock.now < deadline
          },
          { FileManager.default.fileExists(atPath: path) }
        )
        return (result, lastAttempt)
      }
      #expect(result == true)
      #expect(lastAttempt >= 2)
      #expect(!FileManager.default.fileExists(atPath: path))
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
    let overlaps = Lock(0)
    private let inside = Lock(0)
    private(set) var count = 0

    func enter() {
      let isAlone = self.inside.withLock { inside in
        inside += 1
        return inside == 1
      }
      if !isAlone {
        self.overlaps.withLock { $0 += 1 }
      }
      // A read and a write apart, so two holders at once would lose an increment.
      let count = self.count
      for _ in 0..<50 { _ = self.inside.withLock { $0 } }
      self.count = count + 1
      self.inside.withLock { $0 -= 1 }
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
