#if SystemSQLite && (canImport(Darwin) || canImport(Glibc))
  import Foundation
  import StructuredQueries
  import Synchronization
  import Testing

  @testable import SQLiteOrbit

  private enum NativePeerEnvironment {
    static let prefix = "SQLITE_ORBIT_NATIVE_"
    static let mode = prefix + "MODE"
    static let directory = prefix + "DIRECTORY"
    static let database = prefix + "DATABASE"
    static let ready = prefix + "READY"
    static let start = prefix + "START"
    static let opened = prefix + "OPENED"
    static let writerID = prefix + "WRITER_ID"
    static let writeCount = prefix + "WRITE_COUNT"
  }

  /// Checks the guarantees the native driver can only make across real processes.
  @Suite(.serialized)
  struct OrbitDatabaseMultiprocessTests {
    /// Moving a new database into WAL needs an exclusive lock of SQLite's own, so several processes
    /// opening it at the same moment would contend for it if opening were not serialized.
    @Test
    func manyProcessesOpenTheSameNewDatabaseAtOnce() async throws {
      let harness = try NativePeerHarness(name: "native-open")
      defer { harness.cleanup() }
      let openerCount = 8
      let openers = try (0..<openerCount).map { try harness.spawn("open", index: $0) }
      try await harness.waitUntilReady(openerCount)

      try harness.start()

      for (index, opener) in openers.enumerated() {
        try await harness.waitForSuccessfulExit(opener)
        #expect(FileManager.default.fileExists(atPath: harness.file("opened-\(index)").path))
      }
      #expect(FileManager.default.fileExists(atPath: harness.databasePath))

      let mode = try await harness.database().read { transaction in
        try transaction.fetchAll(#sql("PRAGMA journal_mode", as: String.self))
      }
      #expect(mode == ["wal"])
    }

    /// Without a busy timeout, a write that overlaps another process's write fails outright rather
    /// than waiting its turn.
    @Test
    func contentiousWritesFromManyProcessesAllCommit() async throws {
      let harness = try NativePeerHarness(name: "native-write")
      defer { harness.cleanup() }
      let database = try harness.database()
      try await database.write { transaction in
        try transaction.execute(
          "CREATE TABLE writes (id INTEGER PRIMARY KEY, writer_id INTEGER, sequence INTEGER)"
        )
      }

      let writerCount = 4
      let writeCount = 25
      let writers = try (0..<writerCount).map {
        try harness.spawn("write", index: $0, writeCount: writeCount)
      }
      try await harness.waitUntilReady(writerCount)

      try harness.start()

      for writer in writers {
        try await harness.waitForSuccessfulExit(writer)
      }

      let total = try await database.read { transaction in
        try transaction.fetchOne(#sql("SELECT count(*) FROM writes", as: Int.self))
      }
      #expect(total == writerCount * writeCount)
    }
  }

  /// The peer role, selected by the environment. It returns immediately in the parent process,
  /// where no role is set.
  @Test
  func nativeInterprocessDatabasePeer() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let mode = environment[NativePeerEnvironment.mode] else { return }
    func value(_ key: String) throws -> String { try #require(environment[key]) }

    let coordination = UnixDatagramDatabaseIPCTransport.Configuration(
      directory: URL(fileURLWithPath: try value(NativePeerEnvironment.directory)),
      backPressure: .fail
    )
    let path = try value(NativePeerEnvironment.database)
    let ready = URL(fileURLWithPath: try value(NativePeerEnvironment.ready))
    let start = URL(fileURLWithPath: try value(NativePeerEnvironment.start))

    switch mode {
    case "open":
      try touch(ready)
      try await waitForFile(start)
      _ = try OrbitDatabase(path: DatabasePath(path), coordination: coordination)
      try touch(URL(fileURLWithPath: try value(NativePeerEnvironment.opened)))

    case "write":
      let database = try OrbitDatabase(path: DatabasePath(path), coordination: coordination)
      let writerID = try #require(Int(try value(NativePeerEnvironment.writerID)))
      let writeCount = try #require(Int(try value(NativePeerEnvironment.writeCount)))
      try touch(ready)
      try await waitForFile(start)
      for sequence in 0..<writeCount {
        try await database.write { transaction in
          try transaction.execute(
            #sql(
              """
              INSERT INTO writes (writer_id, sequence)
              VALUES (\(bind: writerID), \(bind: sequence))
              """,
              as: Void.self
            )
          )
        }
      }

    default:
      Issue.record("unknown peer mode \(mode)")
      processTestExit(1)
    }
    processTestExit(0)
  }

  private final class NativePeerHarness {
    private let harness: ProcessTestHarness
    let databasePath: String

    var coordination: UnixDatagramDatabaseIPCTransport.Configuration {
      UnixDatagramDatabaseIPCTransport.Configuration(
        directory: self.harness.directory,
        backPressure: .fail
      )
    }

    init(name: String) throws {
      self.harness = try ProcessTestHarness(
        helper: "nativeInterprocessDatabasePeer",
        environmentPrefix: NativePeerEnvironment.prefix,
        name: name
      )
      self.databasePath = self.harness.file("test.sqlite").path
    }

    func file(_ name: String) -> URL { self.harness.file(name) }

    func database() throws -> OrbitDatabase {
      try OrbitDatabase(path: DatabasePath(self.databasePath), coordination: self.coordination)
    }

    func spawn(_ mode: String, index: Int, writeCount: Int = 0) throws -> Process {
      try self.harness.spawn([
        "MODE": mode,
        "DIRECTORY": self.harness.directory.path,
        "DATABASE": self.databasePath,
        "READY": self.harness.file("ready-\(index)").path,
        "START": self.harness.file("start").path,
        "OPENED": self.harness.file("opened-\(index)").path,
        "WRITER_ID": String(index),
        "WRITE_COUNT": String(writeCount)
      ])
    }

    func waitUntilReady(_ count: Int) async throws {
      for index in 0..<count {
        try await waitForFile(self.harness.file("ready-\(index)"))
      }
    }

    func start() throws { try touch(self.harness.file("start")) }

    func waitForSuccessfulExit(_ process: Process) async throws {
      try await self.harness.waitForSuccessfulExit(process)
    }

    func cleanup() { self.harness.cleanup() }
  }
#endif
