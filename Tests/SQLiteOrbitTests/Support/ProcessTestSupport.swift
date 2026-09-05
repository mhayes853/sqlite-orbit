import Foundation

struct TestTimeout: Error {}

// Polls `condition` until it holds, or throws once `timeout` elapses.
//
// Tests wait on a condition rather than on a fixed sleep, so they neither flake under load nor
// pay for a margin that is usually not needed.
func waitUntil(
  timeout: Duration = .seconds(10),
  isolation: isolated (any Actor)? = #isolation,
  _ condition: () -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !condition() {
    guard clock.now < deadline else { throw TestTimeout() }
    try await Task.sleep(for: .milliseconds(2))
  }
}

#if canImport(Darwin) || canImport(Glibc)
  import Testing

  #if canImport(Darwin)
    import Darwin
  #else
    import Glibc
  #endif

  func touch(_ url: URL) throws { try Data().write(to: url, options: .atomic) }

  func waitForFile(_ url: URL, timeout: Duration = .seconds(10)) async throws {
    try await waitUntil(timeout: timeout) { FileManager.default.fileExists(atPath: url.path) }
  }

  func processTestSignal(_ process: Process, _ signal: Int32) {
    #if canImport(Darwin)
      _ = Darwin.kill(process.processIdentifier, signal)
    #else
      _ = Glibc.kill(process.processIdentifier, signal)
    #endif
  }

  func processTestExit(_ status: Int32) -> Never {
    #if canImport(Darwin)
      Darwin.exit(status)
    #else
      Glibc.exit(status)
    #endif
  }

  // Spawns copies of the test binary filtered to a single helper test.
  //
  // Multi-process behavior cannot be observed from one process, so each peer runs the helper test
  // named by `helper` with its role supplied through the environment.
  final class ProcessTestHarness {
    let directory: URL
    private let helper: String
    private let environmentPrefix: String
    private var processes = [Process]()

    init(helper: String, environmentPrefix: String, name: String) throws {
      self.helper = helper
      self.environmentPrefix = environmentPrefix
      self.directory = FileManager.default.temporaryDirectory
        .appending(path: "sqlite-orbit-\(name)-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { self.directory.appending(path: name) }

    func spawn(_ variables: [String: String]) throws -> Process {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = ["--testing-library", "swift-testing", "--filter", self.helper]
      var environment = ProcessInfo.processInfo.environment
      for (name, value) in variables {
        environment[self.environmentPrefix + name] = value
      }
      process.environment = environment
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      self.processes.append(process)
      return process
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

    func cleanup() {
      for process in self.processes where process.isRunning {
        self.kill(process)
        process.waitUntilExit()
      }
      try? FileManager.default.removeItem(at: self.directory)
    }
  }
#endif
