import Benchmark
import BenchmarkSupport
import Foundation
import GRDB
import SQLiteOrbit

// DateParsingTests: parses 50,000 copies of one date text produced by a recursive CTE, so nothing
// but text-to-date decoding varies.
//
// GRDB opens a fresh in-memory DatabaseQueue inside `measure`. Here each connection is opened once,
// outside the measured region, like every other group; opening an in-memory database costs
// microseconds against tens of milliseconds of parsing.
//
// Orbit's `Date` reads ISO 8601 text with a space separator and optional fractional seconds, which
// accepts GRDB's '2018-04-20 14:47:12.345' as it is, so both parse the same text.

private let dateRowCount = 50_000

private let request = """
  WITH RECURSIVE
      cnt(x) AS (
          SELECT 1
          UNION ALL
          SELECT x+1 FROM cnt
          LIMIT 50000
      )
  SELECT '2018-04-20 14:47:12.345' FROM cnt;
  """

private let expectedDate = Date(timeIntervalSince1970: 1_524_235_632.345)

private func expectDates(count: Int, first: Date?) throws {
  try expect(count == dateRowCount, "Parsed \(count) dates instead of \(dateRowCount)")
  guard let first else {
    throw BenchmarkError(message: "Parsed no date")
  }
  try expect(
    abs(first.timeIntervalSince(expectedDate)) < 0.001,
    "Parsed \(first) instead of \(expectedDate)"
  )
}

func registerDateParsing() {
  registerBenchmark(
    "DateParsing/GRDBDateComponents",
    opening: { try DatabaseQueue() },
    measure: { dbQueue in
      let count = try dbQueue.inDatabase { db in
        var count = 0
        let cursor = try DatabaseDateComponents.fetchCursor(db, sql: request)
        while let components = try cursor.next() {
          blackHole(components)
          count += 1
        }
        return count
      }
      try expect(count == dateRowCount, "Parsed \(count) dates instead of \(dateRowCount)")
    }
  )

  registerBenchmark(
    "DateParsing/GRDB",
    opening: { try DatabaseQueue() },
    measure: { dbQueue in
      let (count, first) = try dbQueue.inDatabase { db in
        var count = 0
        var first: Date?
        let cursor = try Date.fetchCursor(db, sql: request)
        while let date = try cursor.next() {
          if first == nil { first = date }
          blackHole(date)
          count += 1
        }
        return (count, first)
      }
      try expectDates(count: count, first: first)
    }
  )

  // Prepared through the statement cache; GRDB prepares each iteration.
  registerBenchmark(
    "DateParsing/Orbit",
    opening: { try OrbitConnection(path: .memory) },
    measure: { connection in
      let (count, first) = try connection.owner.withReadConnection { connection in
        try connection.transaction { transaction in
          var count = 0
          var first: Date?
          var cursor = try transaction.rowCursor(SQLiteOrbit.SQL(text: request))
          while let row = try cursor.next() {
            let date = try row[0, as: Date.self]
            if first == nil { first = date }
            blackHole(date)
            count += 1
          }
          return (count, first)
        }
      }
      try expectDates(count: count, first: first)
    }
  )
}
