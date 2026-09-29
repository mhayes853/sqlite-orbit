#if canImport(Darwin) || os(Linux) || os(Android)
  import Foundation
  import Testing

  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Android)
    import Android
  #endif

  @testable import SQLiteOrbit

  func touch(_ url: URL) throws { try Data().write(to: url, options: .atomic) }

  func waitForFile(_ url: URL, timeout: Duration = .seconds(10)) async throws {
    try await waitUntil(timeout: timeout) { FileManager.default.fileExists(atPath: url.path) }
  }

  /// Waits, for a few seconds at most, until nothing is bound at the socket path `path` whose
  /// socket this process has just closed.
  ///
  /// A process another test spawns at the same moment holds a copy of every descriptor until it
  /// execs, so a socket can outlive its closing here by a little, and still take what is sent to
  /// it.
  func waitUntilNothingIsBound(at path: String) {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while UnixDatagramSocket.probe(path) == .alive, ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
  }

  func processTestSignal(_ process: Process, _ signal: Int32) {
    _ = kill(process.processIdentifier, signal)
  }

  func processTestExit(_ status: Int32) -> Never {
    exit(status)
  }

  /// Waits, in a helper process, for the test to create `url`, and exits with a failure if it
  /// never does, so a helper the test forgot never outlives it for long.
  func processTestWaitForFile(_ url: URL, timeout: Duration = .seconds(30)) {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !FileManager.default.fileExists(atPath: url.path) {
      guard ContinuousClock.now < deadline else { processTestExit(1) }
      Thread.sleep(forTimeInterval: 0.002)
    }
  }

  // MARK: - The test's side

  /// Runs a helper test in processes of its own, with a directory of its own for the test and its
  /// helpers to signal each other through with files.
  ///
  /// Every helper is spawned in a mode, which says what it does, and with an index, which tells it
  /// apart from the others the test spawns. The two sides agree on the rest through the harness's
  /// directory:
  ///
  /// - A helper says it is ready with ``ProcessTestPeer/markReady()``, which the test waits for
  ///   with ``waitUntilReady(_:)``.
  /// - The test tells every helper to begin with ``start()``, and to finish with ``stop()``, which
  ///   they wait for with ``ProcessTestPeer/waitForStart(timeout:)`` and
  ///   ``ProcessTestPeer/waitForStop(timeout:)``.
  /// - A helper reports a number with ``ProcessTestPeer/writeResult(_:)``, which the test reads
  ///   with ``result(_:)``, and anything else it wants seen with ``ProcessTestPeer/mark(_:)``,
  ///   which the test checks with ``isMarked(_:index:)``.
  ///
  /// The helper is a `@Test` that hands its body to ``runProcessTestPeer(_:_:)``, and does nothing
  /// when it runs as part of the suite rather than spawned by a harness. A suite whose tests spawn
  /// helpers should be `.serialized`, since the helpers of tests running at once would compete for
  /// the machine and make every timing in them unreliable.
  ///
  /// ```swift
  /// @Test func counterPeer() async {
  ///   await runProcessTestPeer("counterPeer") { peer in
  ///     try peer.markReady()
  ///     try await peer.waitForStart()
  ///     try peer.writeResult(peer.index * 2)
  ///   }
  /// }
  ///
  /// let harness = try ProcessTestHarness(helper: "counterPeer", name: "count")
  /// defer { harness.cleanup() }
  /// let helpers = try (0..<4).map { try harness.spawn(mode: "count", index: $0) }
  /// try await harness.waitUntilReady(4)
  /// try harness.start()
  /// for helper in helpers { try await harness.waitForSuccessfulExit(helper) }
  /// #expect(try harness.result(3) == 6)
  /// ```
  ///
  /// A harness whose tests share more than this subclasses it, adding what its helpers work on.
  class ProcessTestHarness {
    let directory: URL
    private let helper: String
    private let environmentPrefix: String
    private var processes = [Process]()

    /// The arguments that run one helper test in a process of its own.
    ///
    /// A test process is started differently on each platform: the test executable itself on
    /// Linux, a bundle handed to a runner on Apple platforms. Repeating whatever started this
    /// process, with its filter replaced by the helper's name, is what runs one helper either
    /// way — and dropping the filter this process was given is what keeps a filtered run from
    /// spawning children that run the whole suite again.
    private var arguments: [String] {
      var arguments: [String] = []
      var given = CommandLine.arguments.dropFirst().makeIterator()
      while let argument = given.next() {
        if argument == "--filter" {
          _ = given.next()
          continue
        }
        if argument.hasPrefix("--filter=") { continue }
        arguments.append(argument)
      }
      let filter = ["--filter", self.helper]
      guard !arguments.isEmpty else {
        return ["--testing-library", "swift-testing"] + filter
      }
      // A runner takes the bundle to load as its last argument, so the filter goes ahead of it.
      guard let bundle = arguments.firstIndex(where: { $0.hasSuffix(".xctest") }) else {
        return arguments + filter
      }
      arguments.insert(contentsOf: filter, at: bundle)
      return arguments
    }

    /// Makes a harness, and the directory it and its helpers share.
    ///
    /// - Parameters:
    ///   - helper: The name of the helper test to spawn, which it hands to
    ///     ``runProcessTestPeer(_:_:)`` too.
    ///   - name: A name for the directory, as ``makeShortTemporaryDirectory(_:)`` takes.
    init(helper: String, name: String) throws {
      self.helper = helper
      self.environmentPrefix = ProcessTestPeer.environmentPrefix(helper: helper)
      self.directory = try makeShortTemporaryDirectory(name)
    }

    /// The file `name` in the harness's directory.
    func file(_ name: String) -> URL { self.directory.appending(path: name) }

    /// Spawns the helper in `mode`.
    ///
    /// - Parameters:
    ///   - mode: What the helper does, which it reads as ``ProcessTestPeer/mode``.
    ///   - index: What tells it apart from the other helpers the test spawns, which it reads as
    ///     ``ProcessTestPeer/index``.
    ///   - variables: Anything else it needs, which it reads with ``ProcessTestPeer/string(_:)``
    ///     and its siblings.
    /// - Returns: The helper's process, running.
    @discardableResult
    func spawn(
      mode: String,
      index: Int = 0,
      _ variables: [String: String] = [:]
    ) throws -> Process {
      try self.spawn(
        variables.merging(
          [
            ProcessTestPeer.modeVariable: mode,
            ProcessTestPeer.indexVariable: String(index),
            ProcessTestPeer.directoryVariable: self.directory.path
          ],
          uniquingKeysWith: { _, reserved in reserved }
        )
      )
    }

    private func spawn(_ variables: [String: String]) throws -> Process {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = self.arguments
      var environment = ProcessInfo.processInfo.environment
      for (name, value) in variables {
        environment[self.environmentPrefix + name] = value
      }
      process.environment = environment
      // Kept rather than discarded: a helper that fails says why here, and the test waiting on it
      // can only say that nothing happened.
      let log = self.file("h-\(self.processes.count).log")
      _ = FileManager.default.createFile(atPath: log.path, contents: nil)
      let output = try FileHandle(forWritingTo: log)
      process.standardOutput = output
      process.standardError = output
      try process.run()
      self.processes.append(process)
      return process
    }

    /// What a helper process printed before it stopped.
    ///
    /// - Parameter index: The helper, in the order they were spawned.
    /// - Returns: Its output, or an empty string when it produced none.
    func helperOutput(_ index: Int) -> String {
      (try? String(contentsOf: self.file("h-\(index).log"), encoding: .utf8)) ?? ""
    }

    /// Waits for the helpers of indices `0..<count` to call ``ProcessTestPeer/markReady()``.
    func waitUntilReady(_ count: Int = 1) async throws {
      for index in 0..<count { try await self.waitUntilMarked("ready", index: index) }
    }

    /// Waits for the helper of `index` to call ``ProcessTestPeer/mark(_:)`` with `name`.
    func waitUntilMarked(_ name: String, index: Int = 0) async throws {
      try await waitForFile(self.markFile(name, index: index))
    }

    /// Whether the helper of `index` has called ``ProcessTestPeer/mark(_:)`` with `name`.
    func isMarked(_ name: String, index: Int = 0) -> Bool {
      FileManager.default.fileExists(atPath: self.markFile(name, index: index).path)
    }

    /// Tells every helper waiting in ``ProcessTestPeer/waitForStart(timeout:)`` to begin.
    func start() throws { try touch(self.file(ProcessTestPeer.startFile)) }

    /// Tells every helper waiting in ``ProcessTestPeer/waitForStop(timeout:)`` to finish.
    func stop() throws { try touch(self.file(ProcessTestPeer.stopFile)) }

    /// The number the helper of `index` wrote with ``ProcessTestPeer/writeResult(_:)``.
    func result(_ index: Int = 0) throws -> Int {
      let text = try String(contentsOf: self.markFile("result", index: index), encoding: .utf8)
      return try #require(Int(text))
    }

    func waitForSuccessfulExit(_ process: Process) async throws {
      try await self.waitForExit(process)
      #expect(process.terminationStatus == 0)
    }

    func waitForExit(_ process: Process) async throws {
      try await waitUntil { !process.isRunning }
    }

    func suspend(_ process: Process) { processTestSignal(process, SIGSTOP) }
    func resume(_ process: Process) { processTestSignal(process, SIGCONT) }
    func kill(_ process: Process) { processTestSignal(process, SIGKILL) }

    /// Kills every helper still running, prints what the ones that failed said, and removes the
    /// directory.
    func cleanup() {
      for process in self.processes where process.isRunning {
        self.kill(process)
        process.waitUntilExit()
      }
      self.reportHelpersThatFailed()
      try? FileManager.default.removeItem(at: self.directory)
    }

    private func markFile(_ name: String, index: Int) -> URL {
      self.file(ProcessTestPeer.markFileName(name, index: index))
    }

    /// Prints what the helpers that did not exit cleanly had to say.
    ///
    /// Printed rather than recorded as an issue, because a few of these tests kill their helpers
    /// on purpose, where a non-zero status is the point. A test that waits on a helper can
    /// otherwise only report that nothing happened.
    private func reportHelpersThatFailed() {
      let failed = self.processes.enumerated().filter { $0.element.terminationStatus != 0 }
      guard !failed.isEmpty else { return }
      let command = ([CommandLine.arguments[0]] + self.arguments).joined(separator: " ")
      print("--- helpers of '\(self.helper)', run as: \(command)")
      for (index, process) in failed {
        print("--- helper \(index) exited with \(process.terminationStatus)")
        print(self.helperOutput(index).suffix(2000))
      }
    }
  }

  // MARK: - The helper's side

  /// What a helper process spawned by a ``ProcessTestHarness`` was spawned to do, and its side of
  /// the files the two signal each other through.
  ///
  /// A helper receives one from ``runProcessTestPeer(_:_:)``.
  struct ProcessTestPeer: Sendable {
    /// The mode the harness spawned the helper in.
    let mode: String

    /// What tells the helper apart from the others the test spawned.
    let index: Int

    /// The directory the helper shares with the harness.
    let directory: URL

    private let environmentPrefix: String

    fileprivate init?(helper: String) {
      let environmentPrefix = Self.environmentPrefix(helper: helper)
      let environment = ProcessInfo.processInfo.environment
      guard
        let mode = environment[environmentPrefix + Self.modeVariable],
        let index = environment[environmentPrefix + Self.indexVariable].flatMap({ Int($0) }),
        let directory = environment[environmentPrefix + Self.directoryVariable]
      else { return nil }
      self.mode = mode
      self.index = index
      self.directory = URL(fileURLWithPath: directory)
      self.environmentPrefix = environmentPrefix
    }

    /// The variable `name` the harness spawned the helper with.
    ///
    /// - Throws: When the harness did not set it.
    func string(_ name: String) throws -> String {
      try #require(ProcessInfo.processInfo.environment[self.environmentPrefix + name])
    }

    /// The variable `name` the harness spawned the helper with, as a number.
    ///
    /// - Throws: When the harness did not set it, or it is not a number.
    func int(_ name: String) throws -> Int {
      try #require(Int(try self.string(name)))
    }

    /// The variable `name` the harness spawned the helper with, as the path of a file.
    ///
    /// - Throws: When the harness did not set it.
    func url(_ name: String) throws -> URL {
      URL(fileURLWithPath: try self.string(name))
    }

    /// The file `name` in the directory the helper shares with the harness.
    func file(_ name: String) -> URL { self.directory.appending(path: name) }

    /// Tells the harness the helper is ready, which it waits for with
    /// ``ProcessTestHarness/waitUntilReady(_:)``.
    func markReady() throws { try self.mark("ready") }

    /// Tells the harness the helper has reached the point `name`, which it checks with
    /// ``ProcessTestHarness/isMarked(_:index:)``.
    func mark(_ name: String) throws {
      try touch(self.file(Self.markFileName(name, index: self.index)))
    }

    /// Reports `value`, which the harness reads with ``ProcessTestHarness/result(_:)``.
    func writeResult(_ value: Int) throws {
      try Data(String(value).utf8)
        .write(to: self.file(Self.markFileName("result", index: self.index)), options: .atomic)
    }

    /// Waits for the harness to call ``ProcessTestHarness/start()``.
    func waitForStart(timeout: Duration = .seconds(30)) async throws {
      try await waitForFile(self.file(Self.startFile), timeout: timeout)
    }

    /// Waits for the harness to call ``ProcessTestHarness/stop()``.
    func waitForStop(timeout: Duration = .seconds(30)) async throws {
      try await waitForFile(self.file(Self.stopFile), timeout: timeout)
    }

    /// Waits, blocking the calling thread, for the harness to call ``ProcessTestHarness/start()``,
    /// and exits with a failure if it never does.
    func waitForStartBlocking(timeout: Duration = .seconds(30)) {
      processTestWaitForFile(self.file(Self.startFile), timeout: timeout)
    }

    /// Waits, blocking the calling thread, for the harness to call ``ProcessTestHarness/stop()``,
    /// and exits with a failure if it never does.
    func waitForStopBlocking(timeout: Duration = .seconds(30)) {
      processTestWaitForFile(self.file(Self.stopFile), timeout: timeout)
    }

    /// Thrown by a helper spawned in a mode it does not know.
    struct UnknownModeError: Error, CustomStringConvertible {
      let mode: String
      var description: String { "unknown helper mode '\(self.mode)'" }
    }

    /// The error for the helper's own mode, for a helper that does not know it.
    var unknownMode: UnknownModeError { UnknownModeError(mode: self.mode) }

    fileprivate static let modeVariable = "MODE"
    fileprivate static let indexVariable = "INDEX"
    fileprivate static let directoryVariable = "DIRECTORY"
    fileprivate static let startFile = "start"
    fileprivate static let stopFile = "stop"

    fileprivate static func environmentPrefix(helper: String) -> String {
      "SQLITE_ORBIT_TEST_\(helper)_"
    }

    fileprivate static func markFileName(_ name: String, index: Int) -> String {
      "\(name)-\(index)"
    }
  }

  /// Runs `body` as the helper `helper`, when a ``ProcessTestHarness`` spawned this process to,
  /// and exits with how it went.
  ///
  /// It returns at once, having done nothing, when this process was not spawned as `helper`,
  /// which is what keeps the helper a no-op as part of the suite. Otherwise it never returns: the
  /// process exits with `0` once `body` returns, or prints what `body` threw and exits with `1`.
  ///
  /// ```swift
  /// @Test func openLockPeer() async {
  ///   await runProcessTestPeer("openLockPeer") { peer in
  ///     switch peer.mode {
  ///     case "hold": ...
  ///     default: throw peer.unknownMode
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - helper: The name of the helper test, as its harness was made with.
  ///   - body: What the helper does.
  func runProcessTestPeer(
    _ helper: String,
    _ body: (ProcessTestPeer) async throws -> Void
  ) async {
    guard let peer = ProcessTestPeer(helper: helper) else { return }
    do {
      try await body(peer)
    } catch {
      print("--- helper '\(helper)' in mode '\(peer.mode)' threw: \(error)")
      processTestExit(1)
    }
    processTestExit(0)
  }
#endif
