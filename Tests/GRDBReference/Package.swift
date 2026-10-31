// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "GRDBReference",
  dependencies: [.package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")],
  targets: [
    .testTarget(
      name: "GRDBReferenceTests",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources"
    ),
    // The ported upstream tests with GRDB's own harness, in upstream's language mode.
    .testTarget(
      name: "GRDBUpstreamReferenceTests",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Upstream",
      resources: [.copy("Resources/Betty.jpeg")],
      swiftSettings: [
        .swiftLanguageMode(.v5),
        .enableUpcomingFeature("InferSendableFromCaptures"),
        .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
      ]
    ),
  ]
)
