// swift-tools-version: 6.2

import PackageDescription

// A package of its own, so package-benchmark and GRDB stay out of the library's dependency graph.
// The plugin runs every executable target whose directory sits in one named `Benchmarks`, which
// this package's root is.

#if canImport(Darwin)
  let sqlitePkgConfig: String? = nil
#else
  let sqlitePkgConfig: String? = "sqlite3"
#endif

let benchmarkDependencies: [Target.Dependency] = [
  "BenchmarkSupport",
  "CSQLiteBenchmark",
  .product(name: "SQLiteOrbit", package: "sqlite-orbit"),
  .product(name: "GRDB", package: "GRDB.swift"),
  .product(name: "Benchmark", package: "package-benchmark")
]

let benchmarkSwiftSettings: [SwiftSetting] = [
  .enableExperimentalFeature("Lifetimes")
]

let package = Package(
  name: "sqlite-orbit-benchmarks",
  platforms: [.macOS(.v15)],
  dependencies: [
    // Named, since a path dependency is otherwise identified by its directory, which varies.
    .package(name: "sqlite-orbit", path: ".."),
    .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.37.0"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1")
  ],
  targets: [
    // The raw C baseline every comparison is measured against.
    .systemLibrary(
      name: "CSQLiteBenchmark",
      path: "CSQLiteBenchmark",
      pkgConfig: sqlitePkgConfig
    ),
    .target(
      name: "BenchmarkSupport",
      dependencies: [
        "CSQLiteBenchmark",
        .product(name: "Benchmark", package: "package-benchmark")
      ],
      path: "BenchmarkSupport"
    ),
    .executableTarget(
      name: "FetchBenchmarks",
      dependencies: benchmarkDependencies,
      path: "FetchBenchmarks",
      swiftSettings: benchmarkSwiftSettings,
      plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
    ),
    .executableTarget(
      name: "InsertBenchmarks",
      dependencies: benchmarkDependencies,
      path: "InsertBenchmarks",
      swiftSettings: benchmarkSwiftSettings,
      plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
    )
  ],
  swiftLanguageModes: [.v6]
)
