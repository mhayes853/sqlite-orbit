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
      key_v2: { _, _, bytes, count in
        record(bytes.map { Array(UnsafeRawBufferPointer(start: $0, count: Int(count))) } ?? [])
      },
      rekey_v2: { _, _, _, _ in SQLiteResultCode.ok.rawValue }
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

    let resultCodes = library.extended_result_codes
    library.extended_result_codes = { (connection: OpaquePointer?, on: Int32) -> Int32 in
      events.withLock { $0.append("extended_result_codes") }
      return resultCodes(connection, on)
    }
    let timeout = library.busy_timeout
    library.busy_timeout = { (connection: OpaquePointer?, milliseconds: Int32) -> Int32 in
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

    try await withPooledDatabase(configuration: configuration, maximumReaderCount: 3) { database in
      _ = try await database.read { _ in }
    }

    // A reader that opened unkeyed would find the file unreadable, so the writer being keyed is
    // not enough.
    #expect(keys.withLock { $0.count } == 4)
    #expect(keys.withLock { $0 }.allSatisfy { $0 == Array("open sesame".utf8) })
  }

  @Test
  func theKeyIsSettableThroughImplicitMemberSyntax() {
    // The form the README shows.
    var configuration = SQLiteConfiguration(library: builtInTestLibrary)
    configuration.key = .passphrase("secret")
    #expect(configuration.key != nil)
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

  @Test
  func aWrongKeyFailsTheOpenRatherThanTheFirstQuery() throws {
    // A codec accepts any key and only objects once something reads the file, so without the
    // schema read the open would succeed and the failure would surface somewhere unrelated.
    let keys = Lock<[[UInt8]]>([])
    var configuration = SQLiteConfiguration(
      library: libraryWithFakeCodec { key in
        keys.withLock { $0.append(key) }
        return SQLiteResultCode.ok.rawValue
      }
    )
    configuration.key = SQLiteKey.passphrase("open sesame")
    configuration.setupSQL = ["PRAGMA user_version = 1"]

    // The fake codec cannot make the file unreadable, so the observable part is that the schema
    // was read while configuring, before any setup SQL could run.
    _ = try SQLiteQueue(path: ":memory:", configuration: configuration)
    #expect(keys.withLock { $0.count } == 1)
  }
#endif

#if SQLCipher
  import Foundation
  import SQLCipher

  @Suite(.serialized)
  struct SQLCipherEndToEndTests {
    private func path() -> String {
      temporaryDatabasePath("cipher")
    }

    @Test
    func macroBuildsAnEncryptedTableFromAQualifiedModule() {
      let library = #sqliteLibrary(module: "SQLCipher", encryption: true)

      #expect(library.libversion_number() == SQLiteLibrary.sqlCipher.libversion_number())
      #expect(library.encryption != nil)
    }

    @Test
    func aDatabaseWrittenUnderAKeyIsUnreadableWithoutIt() async throws {
      let path = path()
      defer { try? FileManager.default.removeItem(atPath: path) }

      let writer = try SQLiteQueue(
        path: .file(URL(fileURLWithPath: path)),
        configuration: .sqlCipher(key: .passphrase("open sesame"))
      )
      try await writer.write { transaction in
        try transaction.execute(#sql("CREATE TABLE notes (title TEXT NOT NULL)", as: Void.self))
        try transaction.execute(#sql("INSERT INTO notes VALUES (\'hello\')", as: Void.self))
      }
      _ = consume writer

      #expect(throws: SQLiteError.self) {
        _ = try SQLiteQueue(
          path: .file(URL(fileURLWithPath: path)),
          configuration: .sqlCipher(key: .passphrase("wrong"))
        )
      }

      let reader = try SQLiteQueue(
        path: .file(URL(fileURLWithPath: path)),
        configuration: .sqlCipher(key: .passphrase("open sesame"))
      )
      let titles = try await reader.read { transaction in
        try transaction.fetchAll(#sql("SELECT title FROM notes", as: String.self))
      }
      #expect(titles == ["hello"])
    }

    @Test
    func anEncryptedDatabaseStillRunsCollationsAndFunctions() async throws {
      // The point of removing `supportsTypedCallbacks`: a build that is not the platform SQLite
      // drives Swift callbacks exactly as the linked one does.
      let path = path()
      defer { try? FileManager.default.removeItem(atPath: path) }

      var configuration = SQLiteConfiguration.sqlCipher(key: .passphrase("open sesame"))
      configuration.register(function: $repeated)

      let driver = try SQLiteQueue(
        path: .file(URL(fileURLWithPath: path)),
        configuration: configuration
      )
      let value = try await driver.read { transaction in
        try transaction.fetchOne(#sql("SELECT repeated(\'ab\', 2)", as: String.self))
      }
      #expect(value == "abab")
    }
  }
#endif
