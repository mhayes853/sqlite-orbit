#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

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
/// The bytes this value holds are wiped when the last copy of it goes away. A passphrase built
/// from a `String` cannot wipe the string it was read from, which is the caller's to manage.
public struct SQLiteKey: Sendable {
  private let storage: Storage

  /// A key derived from a passphrase, which the build salts and stretches itself.
  ///
  /// - Parameter passphrase: The passphrase, taken as its UTF-8 bytes.
  public static func passphrase(_ passphrase: String) -> Self {
    Self(storage: Storage(Array(passphrase.utf8)))
  }

  /// A key the caller derived, handed to the build as-is.
  ///
  /// - Parameter bytes: The raw key material.
  public static func raw(_ bytes: [UInt8]) -> Self {
    Self(storage: Storage(bytes))
  }

  func withUnsafeBytes<Result>(
    _ body: (UnsafeRawBufferPointer) throws -> Result
  ) rethrows -> Result {
    try body(UnsafeRawBufferPointer(storage.buffer))
  }

  private final class Storage: @unchecked Sendable {
    let buffer: UnsafeMutableRawBufferPointer

    init(_ bytes: [UInt8]) {
      buffer = .allocate(byteCount: bytes.count, alignment: 1)
      bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
    }

    deinit {
      // Wiped through the platform's explicit erase, which the optimizer may not drop the way it
      // may drop a plain store to memory that is about to be freed.
      if let base = buffer.baseAddress, buffer.count > 0 {
        #if canImport(Darwin)
          memset_s(base, buffer.count, 0, buffer.count)
        #elseif canImport(Glibc)
          explicit_bzero(base, buffer.count)
        #else
          base.initializeMemory(as: UInt8.self, repeating: 0, count: buffer.count)
        #endif
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
