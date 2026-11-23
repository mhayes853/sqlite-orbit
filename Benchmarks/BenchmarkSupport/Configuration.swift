import Benchmark

extension Benchmark.Configuration {
  /// The configuration every suite installs as its default: GRDB's suite measures each test over
  /// 50 iterations, and malloc counts are the metric least disturbed by a noisy machine.
  ///
  /// The bytes allocated come from the same allocator hooks as the malloc count, so they cost
  /// nothing more to measure.
  public static var comparison: Self {
    Benchmark.Configuration(
      metrics: [
        .wallClock,
        .cpuTotal,
        .throughput,
        .mallocCountTotal,
        .mallocBytesCount,
        .peakMemoryResident
      ],
      warmupIterations: 1,
      maxDuration: .seconds(120),
      maxIterations: 50
    )
  }
}
