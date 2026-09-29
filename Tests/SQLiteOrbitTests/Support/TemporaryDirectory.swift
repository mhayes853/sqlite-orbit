import Foundation

/// Creates a temporary directory whose path is short enough to hold a unix socket.
///
/// A socket address carries 104 bytes on Darwin, and the per-user temporary directory there is
/// half of that before a test adds anything, so a directory an IPC transport will put its sockets
/// in has to be brief about the rest.
///
/// Prefer ``withTemporaryDirectory(_:_:)``, which removes the directory again. This is for what
/// outlives a single scope, such as a ``ProcessTestHarness``.
///
/// - Parameter label: A name for what the directory is for, of which the first few characters
///   are kept.
/// - Returns: The directory, created.
func makeShortTemporaryDirectory(_ label: String) throws -> URL {
  let label = label.prefix(8)
  let suffix = String(UInt32.random(in: .min ... .max), radix: 36)
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "\(label)-\(suffix)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

/// Runs `body` with a temporary directory of its own, short enough to hold unix sockets, and
/// removes the directory with everything in it once `body` returns or throws.
///
/// ```swift
/// try withTemporaryDirectory("lock") { directory in
///   try OrbitDatabaseOpenLock.withLock(databaseIdentifier: id, directory: directory, ...) {}
/// }
/// ```
///
/// Swift decides whether a closure throws from the `try`s in its body, without looking inside
/// macros, so a body whose only `try` is inside an `#expect` has to say so: `{ directory throws
/// in`. The same goes for every scoped helper here.
///
/// - Parameters:
///   - label: A name for what the directory is for, as ``makeShortTemporaryDirectory(_:)`` takes.
///   - body: Receives the directory, which exists and is empty.
/// - Returns: Whatever `body` returns.
func withTemporaryDirectory<Result>(
  _ label: String = "tmp",
  _ body: (URL) throws -> Result
) throws -> Result {
  let directory = try makeShortTemporaryDirectory(label)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try body(directory)
}

/// Runs `body` with a temporary directory of its own, as the synchronous
/// ``withTemporaryDirectory(_:_:)`` does, for a body that suspends.
///
/// - Parameters:
///   - label: A name for what the directory is for, as ``makeShortTemporaryDirectory(_:)`` takes.
///   - body: Receives the directory, which exists and is empty.
/// - Returns: Whatever `body` returns.
func withTemporaryDirectory<Result>(
  _ label: String = "tmp",
  isolation: isolated (any Actor)? = #isolation,
  _ body: (URL) async throws -> Result
) async throws -> Result {
  let directory = try makeShortTemporaryDirectory(label)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try await body(directory)
}
