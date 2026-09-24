#if !canImport(Darwin) && !os(Windows) && _runtime(_multithreaded)
  import StructuredQueries
  import Testing

  #if os(Linux)
    import Foundation
  #endif

  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Android)
    import Android
  #elseif canImport(WASILibc)
    import WASILibc
  #endif

  @testable import SQLiteOrbit

  @Suite(.timeLimit(.minutes(1)))
  struct SQLiteConnectionExecutorTests {
    @Test func aBlockingAccessOnAnIdleExecutorRunsOnTheCallingThread() {
      let executor = SQLiteConnectionExecutor(path: .memory)
      let caller = ThreadID.current
      let ranOn = executor.sync {
        executor.checkIsolated()
        return ThreadID.current
      }
      #expect(ranOn == caller)
      #expect(executor.state.startedWorkerCount == 0)
    }

    @Test func jobsShareOneWorkerStartedForTheFirstOfThem() async {
      let executor = SQLiteConnectionExecutor(path: .memory)
      let isolated = ExecutorBoundActor(executor)
      #expect(executor.state.startedWorkerCount == 0)

      let first = await isolated.run {
        executor.checkIsolated()
        return ThreadID.current
      }
      let second = await isolated.run { ThreadID.current }
      #expect(first == second)
      #expect(executor.state.startedWorkerCount == 1)
    }

    @Test func jobsAndBlockingAccessesRunInTheOrderTheyArrived() async throws {
      let executor = SQLiteConnectionExecutor(path: .memory)
      let isolated = ExecutorBoundActor(executor)
      let log = Log()

      // Holding the executor from a blocking access queues everything that follows behind it.
      let gate = Gate()
      let holder = onNewThread { executor.sync { gate.enterAndWait() } }
      try await waitUntil { gate.isEntered }

      var completions = [holder]
      // Each arrival is submitted without waiting on the cooperative pool, and is seen to be queued
      // before the next is submitted.
      for (index, label) in ["A", "B", "C", "D", "E", "F"].enumerated() {
        if index.isMultiple(of: 2) {
          completions.append(Task.immediate { await isolated.run { log.append(label) } })
        } else {
          completions.append(
            onNewThread {
              let caller = ThreadID.current
              executor.sync {
                let isInline = ThreadID.current == caller
                log.append(isInline ? label : "\(label) off its thread")
              }
            }
          )
        }
        try await waitUntil { executor.state.pendingCount == index + 1 }
      }

      gate.open()
      for completion in completions { await completion.value }
      #expect(log.entries == ["A", "B", "C", "D", "E", "F"])
    }

    @Test func anIdleWorkerEndsAndTheNextJobStartsAnother() async throws {
      let executor = SQLiteConnectionExecutor(path: .memory, idleTimeout: .milliseconds(10))
      let isolated = ExecutorBoundActor(executor)

      await isolated.run {}
      #expect(executor.state.startedWorkerCount == 1)
      try await waitUntil { !executor.state.hasRunningWorker }

      let ran = await isolated.run { true }
      #expect(ran)
      #expect(executor.state.startedWorkerCount == 2)
    }

    @Test func releasingTheExecutorEndsItsIdleWorker() async throws {
      let state: SQLiteConnectionExecutor.State
      do {
        let executor = SQLiteConnectionExecutor(path: .memory, idleTimeout: .seconds(600))
        let isolated = ExecutorBoundActor(executor)
        await isolated.run {}
        state = executor.state
      }
      // Well inside the idle timeout, so only the executor going away can have ended the worker.
      try await waitUntil { !state.hasRunningWorker }
    }

    #if os(Linux)
      @Test(
        arguments: [
          (OrbitDatabasePath.memory, "Orbit :memory:"),
          (OrbitDatabasePath.temporary, "Orbit temporary"),
          (OrbitDatabasePath("/var/db/app.db"), "Orbit app.db"),
          // The accent would take the name a byte past the 15 Linux allows, so it is dropped whole
          // rather than split.
          (OrbitDatabasePath("/var/db/abcdefgh\u{E9}.sqlite"), "Orbit abcdefgh")
        ]
      )
      func aWorkerIsNamedForItsDatabase(path: OrbitDatabasePath, expected: String) async throws {
        let isolated = ExecutorBoundActor(SQLiteConnectionExecutor(path: path))
        let name = try await isolated.run {
          try String(contentsOfFile: "/proc/thread-self/comm", encoding: .utf8)
        }
        #expect(name == expected + "\n")
      }
    #endif

    @Test func accessesNeverOverlapWhileWorkersComeAndGo() async {
      let executor = SQLiteConnectionExecutor(path: .memory, idleTimeout: .microseconds(50))
      let isolated = ExecutorBoundActor(executor)
      let occupancy = Occupancy()
      let rounds = 200

      let threads = (0..<4).map { _ in
        onNewThread {
          for round in 0..<rounds {
            executor.sync { occupancy.visit() }
            if round.isMultiple(of: 16) { pauseBriefly() }
          }
        }
      }
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
          group.addTask {
            for round in 0..<rounds {
              await isolated.run {
                executor.checkIsolated()
                occupancy.visit()
              }
              if round.isMultiple(of: 16) { pauseBriefly() }
            }
          }
        }
      }
      for thread in threads { await thread.value }

      #expect(occupancy.visits == 8 * rounds)
      #expect(occupancy.overlaps == 0)
    }

    #if BuiltInSQLite
      @Test func aConnectionSurvivesAsynchronousAndBlockingWritersWhileWorkersComeAndGo()
        async throws
      {
        let connection = try SQLiteSerialConnection(
          path: .memory,
          flags: [.readWrite, .create, .noMutex],
          configuration: .default,
          executor: SQLiteConnectionExecutor(path: .memory, idleTimeout: .microseconds(50))
        )
        try await connection.write { try $0.execute("CREATE TABLE counter (n INTEGER NOT NULL)") }
        try await connection.write { try $0.execute("INSERT INTO counter (n) VALUES (0)") }

        let writers = 6
        let bumpsEach = 100

        let threads = (0..<writers).map { _ in
          onNewThread {
            for bump in 0..<bumpsEach {
              try! connection.writeBlocking { try $0.execute("UPDATE counter SET n = n + 1") }
              _ = try! connection.readBlocking {
                try $0.fetchOne(#sql("SELECT n FROM counter", as: Int.self))
              }
              if bump.isMultiple(of: 16) { pauseBriefly() }
            }
          }
        }
        await withTaskGroup(of: Void.self) { group in
          for _ in 0..<writers {
            group.addTask {
              for bump in 0..<bumpsEach {
                try! await connection.write { try $0.execute("UPDATE counter SET n = n + 1") }
                _ = try! await connection.read {
                  try $0.fetchOne(#sql("SELECT n FROM counter", as: Int.self))
                }
                if bump.isMultiple(of: 16) { pauseBriefly() }
              }
            }
          }
        }
        for thread in threads { await thread.value }

        let total: Int? = try connection.readBlocking {
          try $0.fetchOne(#sql("SELECT n FROM counter", as: Int.self))
        }
        #expect(total == 2 * writers * bumpsEach)
      }
    #endif
  }

  private actor ExecutorBoundActor {
    let executor: SQLiteConnectionExecutor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
      executor.asUnownedSerialExecutor()
    }

    init(_ executor: SQLiteConnectionExecutor) {
      self.executor = executor
    }

    func run<Result: Sendable>(_ body: @Sendable () throws -> Result) rethrows -> Result {
      try body()
    }
  }

  private final class Log: Sendable {
    private let storage = Lock<[String]>([])

    var entries: [String] { storage.withLock { $0 } }

    func append(_ entry: String) {
      storage.withLock { $0.append(entry) }
    }
  }

  // Blocks the thread that enters it until it is opened.
  private final class Gate: Sendable {
    private let state = Lock((isEntered: false, isOpen: false))

    var isEntered: Bool { state.withLock { $0.isEntered } }

    func enterAndWait() {
      state.withLock { $0.isEntered = true }
      while !state.withLock({ $0.isOpen }) { pauseBriefly() }
    }

    func open() {
      state.withLock { $0.isOpen = true }
    }
  }

  // Counts visits made under the executor, and how many found another visit already under way.
  // The counters are deliberately unsynchronized: only the executor keeps them consistent.
  private final class Occupancy: @unchecked Sendable {
    private var isOccupied = false
    private(set) var visits = 0
    private(set) var overlaps = 0

    func visit() {
      if isOccupied { overlaps += 1 }
      isOccupied = true
      visits += 1
      for _ in 0..<50 { _ = ThreadID.current }
      isOccupied = false
    }
  }

  // The thread is started before this returns, however busy the cooperative pool is, and the
  // returned task finishes once it has run `body`.
  private func onNewThread(_ body: @escaping @Sendable () -> Void) -> Task<Void, Never> {
    Task.immediate {
      await withCheckedContinuation { continuation in
        DetachedThread.spawn(name: "executor test") {
          body()
          continuation.resume()
        }
      }
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for the executor")
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private func pauseBriefly() {
    var pause = timespec(tv_sec: 0, tv_nsec: 100_000)
    nanosleep(&pause, nil)
  }
#endif
