#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

// `memset` named indirectly. See `SQLiteKey.Storage.deinit`.
//
// Computed rather than stored: a global of this type is initialized by a function that Swift
// 6.2's isolation checker crashes on, and a computed one is never initialized at all.
private var orbitEraseBytes:
  @convention(c) @Sendable (UnsafeMutableRawPointer, Int32, Int) -> UnsafeMutableRawPointer?
{
  memset
}

/// The key a build with a codec — SQLCipher, say — unlocks a database with.
///
/// The key is handed to the build's `sqlite3_key_v2` as bytes rather than run as `PRAGMA key`, so
/// it never becomes SQL: it is not prepared, not cached, and not carried by the
/// ``SQLiteError/sql`` of a failed open.
///
/// ```swift
/// var configuration = SQLiteConfiguration(library: myCipherBuild)
/// configuration.key = .passphrase(secret)
/// let database = try OrbitDatabase(path: .file(url), configuration: configuration)
/// ```
///
/// The bytes this value holds are wiped when the last copy of it goes away. That limits how long
/// the key sits in freed memory; it is not a guarantee about the process, which may still have it
/// in a swap file or a core dump. Nor can it reach material the caller holds: the `String` a
/// passphrase was read from, or the array handed to ``raw(_:)``, stay theirs to manage.
public struct SQLiteKey: Sendable {
  private let storage: Storage

  /// A key derived from a passphrase, which the build salts and stretches itself.
  ///
  /// - Parameter passphrase: The passphrase, taken as its UTF-8 bytes.
  public static func passphrase(_ passphrase: String) -> Self {
    let utf8 = passphrase.utf8
    return Self(
      storage: Storage(byteCount: utf8.count) { buffer in
        // Copied a byte at a time rather than through an array, which would stage the passphrase
        // in an allocation that is freed without being wiped.
        for (index, byte) in utf8.enumerated() { buffer[index] = byte }
      }
    )
  }

  /// A key the caller derived, handed to the build as-is.
  ///
  /// - Parameter bytes: The raw key material.
  public static func raw(_ bytes: [UInt8]) -> Self {
    Self(
      storage: Storage(byteCount: bytes.count) { buffer in
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
      }
    )
  }

  /// Calls `body` with the key's bytes.
  ///
  /// This is how a caller reaches the material for work the package does not model — calling a
  /// build's `sqlite3_rekey_v2` from a ``SQLiteConnectionSetup``, or keying a database brought in
  /// with `ATTACH`.
  ///
  /// The buffer is only valid for the call. Copying it out puts the key somewhere this type cannot
  /// wipe.
  ///
  /// - Parameter body: Receives the key's bytes.
  /// - Returns: Whatever `body` returned.
  public func withUnsafeBytes<Result: ~Copyable>(
    _ body: (UnsafeRawBufferPointer) throws -> Result
  ) rethrows -> Result {
    try body(UnsafeRawBufferPointer(storage.buffer))
  }

  private final class Storage: @unchecked Sendable {
    let buffer: UnsafeMutableRawBufferPointer

    init(byteCount: Int, fill: (UnsafeMutableRawBufferPointer) -> Void) {
      buffer = .allocate(byteCount: byteCount, alignment: 1)
      fill(buffer)
    }

    deinit {
      // Reached through a function pointer so the compiler cannot see that it is writing to memory
      // about to be freed, and so cannot drop the store as dead. A plain assignment of zeroes here
      // is exactly the store an optimizer is free to remove.
      if let base = buffer.baseAddress, buffer.count > 0 {
        _ = orbitEraseBytes(base, 0, buffer.count)
      }
      buffer.deallocate()
    }
  }
}

extension SQLiteKey: CustomStringConvertible, CustomDebugStringConvertible {
  /// Redacted, so that logging a configuration cannot spill the key.
  public var description: String { "SQLiteKey(redacted)" }

  /// Redacted, so that logging a configuration cannot spill the key.
  public var debugDescription: String { description }
}

/// A key was set for a SQLite build that has no codec to unlock a database with.
///
/// Thrown when a connection is opened with a ``SQLiteConfiguration/key`` but a
/// ``SQLiteLibrary`` whose ``SQLiteLibrary/encryption`` is `nil`. Stock SQLite has no
/// `sqlite3_key_v2`, so this is a fact about the build rather than a claim about it.
public struct SQLiteEncryptionUnavailableError: Error, CustomStringConvertible, Sendable {
  /// Creates the error.
  public init() {}

  /// Explains that the build has no codec.
  public var description: String {
    """
    A key was set for a SQLite build with no codec. Supply a SQLiteLibrary whose `encryption` \
    entry points come from a build that has one, such as SQLCipher.
    """
  }
}
