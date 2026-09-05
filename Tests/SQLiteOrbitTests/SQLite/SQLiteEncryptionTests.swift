#if BuiltInSQLite
  import SQLiteOrbit
  import Synchronization
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
    let events = Mutex<[String]>([])
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
    let keys = Mutex<[[UInt8]]>([])
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
    let keys = Mutex<[[UInt8]]>([])
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
    var configuration = SQLiteConfiguration(library: builtInTestLibrary)
    configuration.key = SQLiteKey.passphrase("open sesame")

    #expect(throws: SQLiteEncryptionUnavailableError.self) {
      _ = try SQLiteQueue(path: ":memory:", configuration: configuration)
    }
  }

  @Test
  func everyConnectionAPoolOpensIsKeyed() async throws {
    let keys = Mutex<[[UInt8]]>([])
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
  func aKeyDoesNotPrintItself() {
    let key = SQLiteKey.passphrase("hunter2")
    #expect("\(key)" == "SQLiteKey(redacted)")
    #expect(String(reflecting: key) == "SQLiteKey(redacted)")
  }
#endif
