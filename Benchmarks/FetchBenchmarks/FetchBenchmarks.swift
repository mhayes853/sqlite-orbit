import Benchmark
import BenchmarkSupport
import CSQLiteBenchmark
import GRDB
import SQLiteOrbit

let benchmarks: @Sendable () -> Void = {
  Benchmark.defaultConfiguration = .comparison
  Benchmark("Smoke/GRDB") { _ in
    try DatabaseQueue().inDatabase { try $0.execute(sql: "SELECT 1") }
  }
  Benchmark("Smoke/Orbit") { _ in
    var owner = try SQLiteConnection(path: .memory, configuration: .default)
    try owner.withWriteConnection { connection in
      try connection.transaction { try $0.execute("SELECT 1") }
    }
  }
}
