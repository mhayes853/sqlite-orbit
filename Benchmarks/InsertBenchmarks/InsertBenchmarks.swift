import Benchmark

// The insert half of GRDB's performance suite (Tests/Performance/GRDBPerformance), one file per
// GRDB test file, with benchmarks named `<GRDBTest>/<Implementation>`.
//
// GRDB's tests delete and recreate the database inside `measure`, so their numbers include opening
// it and creating the table. Here every iteration does that, and opens the connection under test,
// before measurement starts, and verifies the rows and removes the files after it stops, so only
// the inserting transaction and its commit are measured. See `measureInsert`.
//
// Unless a group says otherwise, every implementation runs with SQLite's own defaults, a DELETE
// journal and `synchronous = FULL`: neither GRDB's `DatabaseQueue` nor
// `SQLiteConfiguration.default` changes them. Both libraries enable foreign keys, which no table
// here declares.
let benchmarks: @Sendable () -> Void = {
  Benchmark.defaultConfiguration = .comparison
  insertPositionalValuesBenchmarks()
  insertNamedValuesBenchmarks()
  insertRecordStructBenchmarks()
  insertRecordClassBenchmarks()
  insertRecordEncodableBenchmarks()
  insertRecordOptimizedBenchmarks()
  insertRecordStructuredQueriesBenchmarks()
  argumentsBenchmarks()
  accessOverheadBenchmarks()
}
