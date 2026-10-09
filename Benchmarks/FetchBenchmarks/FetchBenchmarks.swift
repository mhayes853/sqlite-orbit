import Benchmark
import BenchmarkSupport

// The fetch half of GRDB's performance suite (Tests/Performance/GRDBPerformance), one file per
// GRDB test file, with each benchmark named `<GRDB test>/<implementation>`.
let benchmarks: @Sendable () -> Void = {
  Benchmark.defaultConfiguration = .comparison
  registerFetchPositionalValues()
  registerFetchNamedValues()
  registerFetchRecordStruct()
  registerFetchRecordOptimized()
  registerFetchRecordDecodable()
  registerFetchRecordClass()
  registerFetchRecordStructuredQueries()
  registerDateParsing()
  registerReadAccessOverhead()
}
