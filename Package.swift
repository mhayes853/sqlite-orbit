// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "swift-sqlite-cross",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
    .tvOS(.v16),
    .watchOS(.v9),
    .visionOS(.v1)
  ],
  products: [
    .library(name: "SQLiteCross", targets: ["SQLiteCross"])
  ],
  traits: [
    .trait(
      name: "GRDB",
      description: "Builds the optional GRDB database driver."
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    .package(url: "https://github.com/pointfreeco/swift-structured-queries", from: "0.37.0")
  ],
  targets: [
    .target(
      name: "SQLiteCross",
      dependencies: [
        .product(name: "StructuredQueries", package: "swift-structured-queries"),
        .product(
          name: "GRDB",
          package: "GRDB.swift",
          condition: .when(traits: ["GRDB"])
        ),
        .product(
          name: "GRDBSQLite",
          package: "GRDB.swift",
          condition: .when(traits: ["GRDB"])
        )
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("SuppressedAssociatedTypes")
      ]
    ),
    .testTarget(
      name: "SQLiteCrossTests",
      dependencies: [
        "SQLiteCross",
        .product(name: "StructuredQueries", package: "swift-structured-queries"),
        .product(
          name: "GRDB",
          package: "GRDB.swift",
          condition: .when(traits: ["GRDB"])
        )
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("SuppressedAssociatedTypes")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
