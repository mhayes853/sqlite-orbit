import Benchmark

// No GRDB counterpart: the memory a database instance retains. Each iteration opens an instance,
// does some work with it, and keeps it alive until the benchmark ends, so the net bytes malloc'd
// and not freed during the iteration, `memoryLeakedBytes` ("Malloc / free Δ"), is what one open
// instance holds after that work. See `registerMemoryBenchmark`.
let benchmarks: @Sendable () -> Void = {
  registerOpenMemory()
  registerPoolMemory()
  registerStatementMemory()
}
