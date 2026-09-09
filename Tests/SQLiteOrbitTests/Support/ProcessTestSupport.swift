import Foundation

struct TestTimeout: Error {}

/// Creates a temporary directory whose path is short enough to hold a unix socket.
///
/// A socket address carries 104 bytes on Darwin, and the per-user temporary directory there is
/// half of that before a test adds anything, so a directory an IPC transport will put its sockets
/// in has to be brief about the rest.
///
/// - Parameter label: A short name for what the directory is for.
/// - Returns: The directory, created.
func makeShortTemporaryDirectory(_ label: String) throws -> URL {
  let suffix = String(UInt32.random(in: .min ... .max), radix: 36)
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "\(label)-\(suffix)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

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

  final class ProcessTestHarness {
    let directory: URL
    private let helper: String
    private let environmentPrefix: String
    private var processes = [Process]()

    private var arguments: [String] {
      ["--testing-library", "swift-testing", "--filter", self.helper]
    }

    init(helper: String, environmentPrefix: String, name: String) throws {
      self.helper = helper
      self.environmentPrefix = environmentPrefix
      self.directory = try makeShortTemporaryDirectory(name)
    }

    func file(_ name: String) -> URL { self.directory.appending(path: name) }

    func spawn(_ variables: [String: String]) throws -> Process {
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
      FileManager.default.createFile(atPath: log.path, contents: nil)
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
      self.reportHelpersThatFailed()
      try? FileManager.default.removeItem(at: self.directory)
    }

    /// Prints what a helper that failed had to say.
    ///
    /// Printed rather than recorded as an issue, because a few of these tests kill their helpers
    /// on purpose, where a non-zero status is the point.
    private func reportHelpersThatFailed() {
      let command = ([CommandLine.arguments[0]] + self.arguments).joined(separator: " ")
      for (index, process) in self.processes.enumerated() where process.terminationStatus != 0 {
        print("helper \(index) of '\(command)' exited with \(process.terminationStatus)")
        print(self.helperOutput(index).suffix(2000))
      }
    }
  }
#endif
