#if canImport(Darwin) || canImport(Glibc)
  import Foundation
  import Synchronization
  import Testing

  @testable import SQLiteCross

  private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "sqlite-cross-open-lock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test
  func openLockMakesASecondAcquisitionWaitForTheFirst() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseIdentifier = DatabaseIdentifier(rawValue: "open-lock")
    let order = Mutex([String]())
    let isHeld = Mutex(false)
    let mayRelease = Mutex(false)

    Thread.detachNewThread {
      try? DatabaseOpenLock.withLock(
        databaseIdentifier: databaseIdentifier,
        directory: directory
      ) {
        isHeld.withLock { $0 = true }
        while !mayRelease.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
        order.withLock { $0.append("first") }
      }
    }
    try await waitUntil { isHeld.withLock { $0 } }

    let didAcquireSecond = Mutex(false)
    Thread.detachNewThread {
      try? DatabaseOpenLock.withLock(
        databaseIdentifier: databaseIdentifier,
        directory: directory
      ) {
        order.withLock { $0.append("second") }
        didAcquireSecond.withLock { $0 = true }
      }
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(order.withLock { $0 }.isEmpty)

    mayRelease.withLock { $0 = true }
    try await waitUntil { didAcquireSecond.withLock { $0 } }
    #expect(order.withLock { $0 } == ["first", "second"])
  }

  @Test
  func openLockDoesNotBlockDifferentDatabases() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let isHeld = Mutex(false)
    let mayRelease = Mutex(false)

    Thread.detachNewThread {
      try? DatabaseOpenLock.withLock(
        databaseIdentifier: DatabaseIdentifier(rawValue: "one"),
        directory: directory
      ) {
        isHeld.withLock { $0 = true }
        while !mayRelease.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
      }
    }
    try await waitUntil { isHeld.withLock { $0 } }
    defer { mayRelease.withLock { $0 = true } }

    let didAcquire = try DatabaseOpenLock.withLock(
      databaseIdentifier: DatabaseIdentifier(rawValue: "two"),
      directory: directory
    ) { true }
    #expect(didAcquire)
  }
#endif
