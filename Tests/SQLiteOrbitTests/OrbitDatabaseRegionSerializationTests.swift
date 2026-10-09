import Foundation
import SQLiteOrbit
import Testing

@Suite
struct OrbitDatabaseRegionSerializationTests {
  @Test(arguments: regionWireFixtures)
  func versionOneMatchesIndependentFixtures(_ fixture: RegionWireFixture) throws {
    #expect(fixture.region.serialized() == fixture.bytes)
    #expect(try decodeRegion(fixture.bytes) == fixture.region)
  }

  @Test(arguments: serializationRegions)
  func algebraAndIdentifierSpellingsRoundTrip(_ region: OrbitDatabaseRegion) throws {
    let bytes = region.serialized()
    let decoded = try decodeRegion(bytes)
    #expect(decoded == region)
    #expect(decoded.serialized() == bytes)
  }

  @Test(arguments: [127, 128, 16_383, 16_384, 65_536])
  func longNamesCrossVarintBoundaries(length: Int) throws {
    let region = OrbitDatabaseRegion(
      column: String(repeating: "c", count: length),
      in: String(repeating: "t", count: length),
      schema: SQLiteSchemaName(String(repeating: "s", count: length))
    )
    let lengthBytes: [Int: [UInt8]] = [
      127: [0x7f], 128: [0x80, 1], 16_383: [0xff, 0x7f],
      16_384: [0x80, 0x80, 1], 65_536: [0x80, 0x80, 4]
    ]
    let expectedLength = try #require(lengthBytes[length])
    let bytes = region.serialized()
    #expect(Array(bytes.dropFirst(4).prefix(expectedLength.count)) == expectedLength)
    #expect(try decodeRegion(bytes) == region)
  }

  @Test(arguments: [false, true])
  func countsAndIndicesCrossTheSingleByteBoundary(tables: Bool) throws {
    let region =
      tables
      ? (0..<128)
        .reduce(OrbitDatabaseRegion.empty) {
          $0.union(OrbitDatabaseRegion(table: "t\($1)"))
        }
      : OrbitDatabaseRegion(columns: (0..<128).map { "c\($0)" }, in: "items")
    let bytes = region.serialized()
    #expect(Array(bytes.prefix(5)) == [0, 1, 0, tables ? 129 : 130, 1])
    #expect(try decodeRegion(bytes) == region)
  }

  @Test(arguments: malformedRegionBytes)
  func malformedWireDataThrowsDecodingError(_ fixture: MalformedRegionBytes) {
    #expect(throws: DecodingError.self) { try decodeRegion(fixture.bytes) }
  }

  @Test(arguments: regionWireFixtures)
  func codableWrapsTheSameBytesInJSONAndPropertyLists(_ fixture: RegionWireFixture) throws {
    let json = try JSONEncoder().encode(fixture.region)
    #expect(try JSONDecoder().decode([UInt8].self, from: json) == fixture.bytes)
    #expect(try JSONDecoder().decode(OrbitDatabaseRegion.self, from: json) == fixture.region)
    let plist = try PropertyListEncoder().encode(fixture.region)
    #expect(try PropertyListDecoder().decode([UInt8].self, from: plist) == fixture.bytes)
    #expect(
      try PropertyListDecoder().decode(OrbitDatabaseRegion.self, from: plist) == fixture.region
    )

    let malformedJSON = try JSONEncoder().encode([UInt8](fixture.bytes.dropLast()))
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(OrbitDatabaseRegion.self, from: malformedJSON)
    }
  }
}

private func decodeRegion(_ bytes: [UInt8]) throws -> OrbitDatabaseRegion {
  try bytes.withUnsafeBufferPointer {
    try OrbitDatabaseRegion(serialized: Span(_unsafeElements: $0))
  }
}

struct RegionWireFixture: Sendable {
  let region: OrbitDatabaseRegion
  let bytes: [UInt8]
}

private let regionWireFixtures: [RegionWireFixture] = [
  RegionWireFixture(region: .empty, bytes: [0, 1, 0, 0, 0]),
  RegionWireFixture(region: .fullDatabase, bytes: [0, 1, 1, 0, 0]),
  RegionWireFixture(
    region: OrbitDatabaseRegion.fullDatabase
      .subtracting(OrbitDatabaseRegion(table: "logs", schema: "archive"))
      .subtracting(OrbitDatabaseRegion(columns: ["z", "a"], in: "items")),
    // Strings: a, archive, items, logs, main, z. Tables: archive.logs, main.items.
    bytes: [
      0, 1, 1, 6,
      1, 0x61, 7, 0x61, 0x72, 0x63, 0x68, 0x69, 0x76, 0x65,
      5, 0x69, 0x74, 0x65, 0x6d, 0x73, 4, 0x6c, 0x6f, 0x67, 0x73,
      4, 0x6d, 0x61, 0x69, 0x6e, 1, 0x7a,
      2, 1, 3, 0, 0, 4, 2, 1, 2, 0, 5
    ]
  ),
  RegionWireFixture(
    region: OrbitDatabaseRegion(columns: ["z", "e\u{301}"], in: "e\u{301}")
      .union(OrbitDatabaseRegion(table: "z")),
    // Decomposed e-acute sorts before main and z by UTF-8, including table/column order.
    bytes: [
      0, 1, 0, 3, 3, 0x65, 0xcc, 0x81, 4, 0x6d, 0x61, 0x69, 0x6e, 1, 0x7a,
      2, 1, 0, 0, 2, 0, 2, 1, 2, 1, 0
    ]
  ),
  RegionWireFixture(
    region: OrbitDatabaseRegion(column: "title", in: "e\u{301}", schema: "é"),
    // Canonically equal schema/table spellings remain distinct strings on the wire.
    bytes: [
      0, 1, 0, 3, 3, 0x65, 0xcc, 0x81, 5, 0x74, 0x69, 0x74, 0x6c, 0x65,
      2, 0xc3, 0xa9, 1, 2, 0, 0, 1, 1
    ]
  )
]

private let serializationRegions: [OrbitDatabaseRegion] = {
  let items = OrbitDatabaseRegion(table: "items")
  let title = OrbitDatabaseRegion(column: "title", in: "items")
  let attached = OrbitDatabaseRegion(columns: ["id", "name"], in: "records", schema: "ARCHIVE")
  return regionWireFixtures.map(\.region) + [
    items, title, items.subtracting(title), .fullDatabase.subtracting(items),
    title.union(attached), items.symmetricDifference(attached),
    OrbitDatabaseRegion.fullDatabase.subtracting(title).intersection(items.union(attached)),
    OrbitDatabaseRegion(column: "a\0b", in: "", schema: "")
  ]
}()

struct MalformedRegionBytes: Sendable, CustomTestStringConvertible {
  let testDescription: String
  let bytes: [UInt8]
}

private let malformedRegionBytes: [MalformedRegionBytes] = {
  // These small fixtures use only single-byte counts/indices, independent of the encoder.
  func wire(_ strings: [String], _ tables: [[UInt8]], flags: UInt8 = 0) -> [UInt8] {
    var bytes: [UInt8] = [0, 1, flags, UInt8(strings.count)]
    for string in strings {
      bytes.append(UInt8(string.utf8.count))
      bytes.append(contentsOf: string.utf8)
    }
    bytes.append(UInt8(tables.count))
    for table in tables { bytes.append(contentsOf: table) }
    return bytes
  }
  let strings = ["main", "items", "title"]
  var cases: [(String, [UInt8])] = [
    ("unsupported version", [0, 2, 0, 0, 0]),
    ("unsupported high version byte", [1, 1, 0, 0, 0]),
    ("unknown region flags", [0, 1, 2, 0, 0]),
    ("unknown table flags", wire(strings, [[0, 1, 2, 0]])),
    ("malformed UTF-8", [0, 1, 0, 1, 1, 0xff, 0]),
    ("schema index", wire(strings, [[3, 1, 0, 0]])),
    ("table index", wire(strings, [[0, 3, 0, 0]])),
    ("column index", wire(strings, [[0, 1, 0, 1, 3]])),
    ("duplicate normalized tables", wire(["main", "items", "ITEMS"], [[0, 1, 1, 0], [0, 2, 1, 0]])),
    ("duplicate normalized schemas", wire(["main", "MAIN", "items"], [[0, 2, 1, 0], [1, 2, 1, 0]])),
    (
      "duplicate normalized columns",
      wire(["main", "items", "title", "TITLE"], [[0, 1, 0, 2, 2, 3]])
    ),
    ("UInt64 overflow", [0, 1, 0] + Array(repeating: 0xff, count: 9) + [2]),
    ("Int overflow", [0, 1, 0] + Array(repeating: 0xff, count: 9) + [1]),
    ("unterminated varint", [0, 1, 0] + Array(repeating: 0x80, count: 10)),
    ("nonminimal string count", [0, 1, 0, 0x80, 0, 0]),
    ("nonminimal string length", [0, 1, 0, 1, 0x80, 0, 0]),
    ("nonminimal table count", [0, 1, 0, 0, 0x80, 0]),
    ("nonminimal schema index", wire(strings, [[0x80, 0, 1, 0, 0]])),
    ("nonminimal table index", wire(strings, [[0, 0x81, 0, 0, 0]])),
    ("nonminimal exception count", wire(strings, [[0, 1, 0, 0x80, 0]])),
    ("nonminimal column index", wire(strings, [[0, 1, 0, 1, 0x82, 0]]))
  ]
  let bytes = regionWireFixtures[2].bytes
  cases += bytes.indices.map { ("truncated at \($0)", Array(bytes.prefix($0))) }
  cases.append(("trailing byte", bytes + [0]))
  return cases.map { MalformedRegionBytes(testDescription: $0.0, bytes: $0.1) }
}()
