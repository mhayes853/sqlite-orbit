#if BuiltInSQLite
  @testable import SQLiteOrbit
  import Testing

  // A codec the built-in build does not actually have. Stock SQLite never sees the key, which is
  // what makes the plumbing — the ordering, the bytes handed over, the error a refusal produces —
  // testable without an encrypted build.
  private func libraryWithFakeCodec(
    _ record: @escaping @Sendable ([UInt8]) -> Int32
  ) -> SQLiteLibrary {
    var library = builtInTestLibrary
    library.encryption = SQLiteLibrary.Encryption(
      key: { _, _, bytes, count in
        record(bytes.map { Array(UnsafeRawBufferPointer(start: $0, count: Int(count))) } ?? [])
      },
      rekey: { _, _, _, _ in SQLiteResultCode.ok.rawValue }
    )
    return library
  }

  @Test
  func theKeyIsAppliedBeforeAnythingElseTheConnectionDoes() throws {
    let events = Lock<[String]>([])
    var library = libraryWithFakeCodec { _ in
      events.withLock { $0.append("key") }
      return SQLiteResultCode.ok.rawValue
    }

    let resultCodes = library.connections.setExtendedResultCodes
    library.connections.setExtendedResultCodes = {
      (connection: OpaquePointer?, on: Int32) -> Int32 in
      events.withLock { $0.append("extended_result_codes") }
      return resultCodes(connection, on)
    }
    let timeout = library.connections.setBusyTimeout
    library.connections.setBusyTimeout = {
      (connection: OpaquePointer?, milliseconds: Int32) -> Int32 in
      events.withLock { $0.append("busy_timeout") }
      return timeout(connection, milliseconds)
    }

    var configuration = SQLiteConfiguration(library: library)
    configuration.key = SQLiteKey.passphrase("open sesame")
    _ = try SQLiteQueue(path: ":memory:", configuration: configuration)

    // Not merely before the first statement: before every other thing the connection does.
    #expect(events.withLock { $0.first } == "key")
  }

  @Test
  func aPassphraseReachesTheBuildAsItsUTF8() throws {
    let keys = Lock<[[UInt8]]>([])
    var configuration = SQLiteConfiguration(
      library: libraryWithFakeCodec { key in
        keys.withLock { $0.append(key) }
        return SQLiteResultCode.ok.rawValue
      }
    )
    configuration.key = SQLiteKey.passphrase("öpen sesame")
    _ = try SQLiteQueue(path: ":memory:", configuration: configuration)

    #expect(keys.withLock { $0 } == [Array("öpen sesame".utf8)])
  }

  @Test
  func aRawKeyReachesTheBuildUnchanged() throws {
    let keys = Lock<[[UInt8]]>([])
    var configuration = SQLiteConfiguration(
      library: libraryWithFakeCodec { key in
        keys.withLock { $0.append(key) }
        return SQLiteResultCode.ok.rawValue
      }
    )
    configuration.key = SQLiteKey.raw([0x00, 0xFF, 0x10, 0x00, 0x7F])
    _ = try SQLiteQueue(path: ":memory:", configuration: configuration)

    // Interior zero bytes included, which a key read as a C string would have cut short.
    #expect(keys.withLock { $0 } == [[0x00, 0xFF, 0x10, 0x00, 0x7F]])
  }

  @Test
  func aRefusedKeyReportsTheFailureWithoutCarryingTheKey() throws {
    var configuration = SQLiteConfiguration(
      library: libraryWithFakeCodec { _ in SQLiteResultCode.notADatabase.rawValue }
    )
    configuration.key = SQLiteKey.passphrase("hunter2")

    let error = #expect(throws: SQLiteError.self) {
      _ = try SQLiteQueue(path: ":memory:", configuration: configuration)
    }
    #expect(error?.primaryCode == .notADatabase)
    // The key is handed over as bytes, so there is no SQL for it to have leaked into.
    #expect(error?.sql == nil)
    #expect(error?.description.contains("hunter2") == false)
  }

  @Test
  func aKeyWithoutACodecIsRefusedRatherThanIgnored() throws {
    // Explicitly codec-less, because the built-in build may well have one.
    var library = builtInTestLibrary
    library.encryption = nil
    var configuration = SQLiteConfiguration(library: library)
    configuration.key = SQLiteKey.passphrase("open sesame")

    #expect(throws: SQLiteEncryptionUnavailableError.self) {
      _ = try SQLiteQueue(path: ":memory:", configuration: configuration)
    }
  }

  @Test
  func everyConnectionAPoolOpensIsKeyed() async throws {
    let keys = Lock<[[UInt8]]>([])
    var configuration = SQLiteConfiguration(
      library: libraryWithFakeCodec { key in
        keys.withLock { $0.append(key) }
        return SQLiteResultCode.ok.rawValue
      }
    )
    configuration.key = SQLiteKey.passphrase("open sesame")

    try await withPooledDatabase(configuration: configuration, readerCount: 3) { database in
      _ = try await database.read { _ in }
    }

    // A reader that opened unkeyed would find the file unreadable, so the writer being keyed is
    // not enough.
    #expect(keys.withLock { $0.count } == 4)
    #expect(keys.withLock { $0 }.allSatisfy { $0 == Array("open sesame".utf8) })
  }

  @Test
  func aKeyLendsItsBytesForWorkThePackageDoesNotModel() {
    // Rekeying and keying an ATTACHed database both go through the build directly, so the key has
    // to be reachable rather than only handable to a configuration.
    let passphrase = SQLiteKey.passphrase("öpen sesame")
    #expect(passphrase.withUnsafeBytes { Array($0) } == Array("öpen sesame".utf8))

    let raw = SQLiteKey.raw([0x00, 0xFF, 0x00])
    #expect(raw.withUnsafeBytes { Array($0) } == [0x00, 0xFF, 0x00])
  }

  @Test
  func aKeyDoesNotPrintItself() {
    let key = SQLiteKey.passphrase("hunter2")
    #expect("\(key)" == "SQLiteKey(redacted)")
    #expect(String(reflecting: key) == "SQLiteKey(redacted)")
  }
#endif

#if SQLCipher
  import Foundation
  import SQLCipher

  @Suite(.serialized)
  struct SQLCipherEndToEndTests {
    @Test
    func macroBuildsAnEncryptedTableFromAQualifiedModule() {
      let library = #sqliteLibrary(module: "SQLCipher", apis: [.standard, .encryption])

      #expect(library.runtime.versionNumber() == SQLiteLibrary.sqlCipher.runtime.versionNumber())
      #expect(library.encryption != nil)
    }

    @Test
    func aDatabaseWrittenUnderAKeyIsUnreadableWithoutIt() async throws {
      try await withTestDatabaseFile("cipher") { file in
        let writer = try SQLiteQueue(
          path: file.path,
          configuration: .sqlCipher(key: .passphrase("open sesame"))
        )
        try await writer.write { transaction in
          try transaction.execute("CREATE TABLE notes (title TEXT NOT NULL)")
          try transaction.execute("INSERT INTO notes VALUES (\'hello\')")
        }
        _ = consume writer

        #expect(throws: SQLiteError.self) {
          _ = try SQLiteQueue(
            path: file.path,
            configuration: .sqlCipher(key: .passphrase("wrong"))
          )
        }

        let reader = try SQLiteQueue(
          path: file.path,
          configuration: .sqlCipher(key: .passphrase("open sesame"))
        )
        let titles = try await reader.read { transaction in
          try transaction.fetchAll("SELECT title FROM notes", as: String.self)
        }
        #expect(titles == ["hello"])
      }
    }

    @Test
    func rekeyingToRawBytesKeepsTheDataAndRejectsTheOldKey() async throws {
      try await withTestDatabaseFile("cipher") { file in
        let oldKey = SQLiteKey.passphrase("old passphrase")
        let newKey = SQLiteKey.raw([0x00, 0xFF, 0x42, 0x10, 0x00, 0x7F])
        let database = try SQLiteQueue(
          path: file.path,
          configuration: .sqlCipher(key: oldKey)
        )
        try await database.write { transaction in
          try transaction.execute("CREATE TABLE notes (title TEXT NOT NULL)")
          try transaction.execute("INSERT INTO notes VALUES ('survives')")
        }

        try await database.writeWithoutTransaction { connection in
          let encryption = try #require(connection.sqlite.encryption)
          let code = newKey.withUnsafeBytes { bytes in
            encryption.rekey(
              connection.sqliteConnection,
              "main",
              bytes.baseAddress,
              Int32(bytes.count)
            )
          }
          #expect(code == SQLiteResultCode.ok.rawValue)
        }
        _ = consume database

        #expect(throws: SQLiteError.self) {
          _ = try SQLiteQueue(path: file.path, configuration: .sqlCipher(key: oldKey))
        }

        let reopened = try SQLiteQueue(
          path: file.path,
          configuration: .sqlCipher(key: newKey)
        )
        let titles = try await reopened.read { transaction in
          try transaction.fetchAll("SELECT title FROM notes", as: String.self)
        }
        #expect(titles == ["survives"])
      }
    }

    @Test
    func anEncryptedDatabaseStillRunsCollationsAndFunctions() async throws {
      // The point of removing `supportsTypedCallbacks`: a build that is not the platform SQLite
      // drives Swift callbacks exactly as the linked one does.
      try await withTestDatabaseFile("cipher") { file in
        var configuration = SQLiteConfiguration.sqlCipher(key: .passphrase("open sesame"))
        configuration.registerFunction("repeated", argumentCount: 2, flags: [.deterministic]) {
          arguments in
          guard let text = arguments[0].textValue, let count = arguments[1].integerValue else {
            return nil
          }
          return .text(String(repeating: text, count: Int(count)))
        }

        let driver = try SQLiteQueue(
          path: file.path,
          configuration: configuration
        )
        let value = try await driver.read { transaction in
          try transaction.fetchOne("SELECT repeated(\'ab\', 2)", as: String.self)
        }
        #expect(value == "abab")
      }
    }
  }
#endif
