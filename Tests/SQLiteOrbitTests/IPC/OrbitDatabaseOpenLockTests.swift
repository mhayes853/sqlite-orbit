#if canImport(Darwin) || canImport(Glibc)
  import Dispatch
  import Foundation
  import Testing

  @testable import SQLiteOrbit

  private final class OpenLockHolder: Sendable {
    private let acquired = DispatchSemaphore(value: 0)
    private let mayRelease = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    init(
      _ databaseIdentifier: OrbitDatabaseIdentifier,
      in directory: URL,
      onRelease: @escaping @Sendable () -> Void = {}
    ) {
      Thread.detachNewThread {
        try? OrbitDatabaseOpenLock.withLock(
          databaseIdentifier: databaseIdentifier,
          directory: directory
        ) {
          self.acquired.signal()
          self.mayRelease.wait()
          onRelease()
        }
        self.released.signal()
      }
      acquired.wait()
    }

    func release() {
      mayRelease.signal()
      released.wait()
    }
  }

  private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "sqlite-orbit-open-lock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test
  func openLockMakesASecondAcquisitionWaitForTheFirst() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseIdentifier = OrbitDatabaseIdentifier(rawValue: "open-lock")
    let order = Lock([String]())

    let holder = OpenLockHolder(databaseIdentifier, in: directory) {
      order.withLock { $0.append("first") }
    }

    let didAcquireSecond = Lock(false)
    Thread.detachNewThread {
      try? OrbitDatabaseOpenLock.withLock(
        databaseIdentifier: databaseIdentifier,
        directory: directory
      ) {
        order.withLock { $0.append("second") }
        didAcquireSecond.withLock { $0 = true }
      }
    }

    // The second acquisition cannot be observed to *not* happen without giving it a chance to.
    try await Task.sleep(for: .milliseconds(50))
    #expect(order.withLock { $0 }.isEmpty)

    holder.release()
    try await waitUntil { didAcquireSecond.withLock { $0 } }
    #expect(order.withLock { $0 } == ["first", "second"])
  }

  @Test
  func openLockDoesNotBlockDifferentDatabases() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let holder = OpenLockHolder(OrbitDatabaseIdentifier(rawValue: "one"), in: directory)
    defer { holder.release() }

    let didAcquire = try OrbitDatabaseOpenLock.withLock(
      databaseIdentifier: OrbitDatabaseIdentifier(rawValue: "two"),
      directory: directory
    ) { true }
    #expect(didAcquire)
  }
#endif
