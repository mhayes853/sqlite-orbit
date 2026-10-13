import Benchmark
import BenchmarkSupport
import SQLiteOrbit

// GRDB's fetch tests open their database once, before `measure`, and reuse it in every iteration.
// These helpers do the same: a benchmark's resource is opened in its setup and released in its
// teardown, so neither is measured.

/// Registers a benchmark that measures `body` against a resource opened before its iterations.
///
/// - Parameters:
///   - name: The benchmark's name, as `<GRDB test>/<implementation>`.
///   - configuration: The benchmark's configuration, the suite's default unless given.
///   - open: Opens the resource, outside the measured region.
///   - cleanUp: Runs after the resource is released, to remove anything `open` created.
///   - body: The measured work.
func registerBenchmark<Resource>(
  _ name: String,
  configuration: Benchmark.Configuration = Benchmark.defaultConfiguration,
  opening open: @escaping () async throws -> Resource,
  cleanUp: @escaping () -> Void = {},
  measure body: @escaping (Resource) throws -> Void
) {
  let holder = ResourceHolder<Resource>()
  Benchmark(
    name,
    configuration: configuration,
    closure: { benchmark in
      let resource = try holder.resource(for: name)
      for _ in benchmark.scaledIterations {
        try body(resource)
      }
    },
    setup: { holder.value = try await open() },
    teardown: {
      holder.value = nil
      cleanUp()
    }
  )
}

/// Registers a benchmark that measures asynchronous `body` against a resource opened before its
/// iterations.
func registerBenchmark<Resource>(
  _ name: String,
  configuration: Benchmark.Configuration = Benchmark.defaultConfiguration,
  opening open: @escaping () async throws -> Resource,
  cleanUp: @escaping () -> Void = {},
  measure body: @escaping (Resource) async throws -> Void
) {
  let holder = ResourceHolder<Resource>()
  Benchmark(
    name,
    configuration: configuration,
    closure: { benchmark in
      let resource = try holder.resource(for: name)
      for _ in benchmark.scaledIterations {
        try await body(resource)
      }
    },
    setup: { holder.value = try await open() },
    teardown: {
      holder.value = nil
      cleanUp()
    }
  )
}

private final class ResourceHolder<Value> {
  var value: Value?

  func resource(for name: String) throws -> Value {
    guard let value else {
      throw BenchmarkError(message: "\(name) ran without its setup")
    }
    return value
  }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
  guard condition else { throw BenchmarkError(message: message()) }
}

// MARK: - Fixture expectations

/// The sum of every column of every fixture row, where row `n` stores `n` in all ten columns.
///
/// Value benchmarks add up what they read rather than discarding it, which keeps the optimizer
/// from dropping the reads and checks every value with one comparison.
let expectedFetchedValueSum = 10 * (Fixture.fetchedRowCount - 1) * Fixture.fetchedRowCount / 2

func expectFetchedValues(count: Int, sum: Int) throws {
  try expect(
    count == Fixture.fetchedRowCount,
    "Read \(count) rows instead of \(Fixture.fetchedRowCount)"
  )
  try expect(sum == expectedFetchedValueSum, "Read values summing to \(sum)")
  blackHole(sum)
}

/// Checks fetched records the way GRDB's tests do: their count, and three spot values.
func expectFetchedRecords<Record>(
  _ records: [Record],
  i0: (Record) -> Int,
  i1: (Record) -> Int,
  i9: (Record) -> Int
) throws {
  let last = Fixture.fetchedRowCount - 1
  try expect(
    records.count == Fixture.fetchedRowCount,
    "Fetched \(records.count) records instead of \(Fixture.fetchedRowCount)"
  )
  try expect(i0(records[0]) == 0, "records[0].i0 is \(i0(records[0]))")
  try expect(i1(records[1]) == 1, "records[1].i1 is \(i1(records[1]))")
  try expect(i9(records[last]) == last, "records[\(last)].i9 is \(i9(records[last]))")
  blackHole(records)
}

// MARK: - Connections

/// A box for the noncopyable synchronous connection owner, so a benchmark can hold it across
/// iterations.
final class OrbitConnection {
  var owner: SQLiteConnection

  init(path: String) throws {
    owner = try SQLiteConnection(path: OrbitDatabasePath(path), configuration: .default)
  }

  init(path: OrbitDatabasePath) throws {
    owner = try SQLiteConnection(path: path, configuration: .default)
  }
}
