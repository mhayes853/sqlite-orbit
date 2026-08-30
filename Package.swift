// swift-tools-version: 6.1

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
    .library(name: "SQLiteCross", targets: ["SQLiteCross"]),
    .library(name: "SQLiteCrossGRDB", targets: ["SQLiteCrossGRDB"]),
    .library(
      name: "SQLiteCrossStructuredQueries",
      targets: ["SQLiteCrossStructuredQueries"]
    )
  ],
  traits: [
    .trait(
      name: "SQLiteCrossGRDB",
      description: "Builds the GRDB local database driver adapter."
    ),
    .trait(
      name: "SQLiteCrossStructuredQueries",
      description: "Builds type-safe table region helpers for swift-structured-queries."
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    .package(url: "https://github.com/pointfreeco/swift-structured-queries", from: "0.37.0")
  ],
  targets: [
    .target(name: "SQLiteCross"),
    .target(
      name: "SQLiteCrossGRDB",
      dependencies: [
        "SQLiteCross",
        .product(
          name: "GRDB",
          package: "GRDB.swift",
          condition: .when(traits: ["SQLiteCrossGRDB"])
        )
      ]
    ),
    .target(
      name: "SQLiteCrossStructuredQueries",
      dependencies: [
        "SQLiteCross",
        .product(
          name: "StructuredQueries",
          package: "swift-structured-queries",
          condition: .when(traits: ["SQLiteCrossStructuredQueries"])
        )
      ]
    ),
    .testTarget(
      name: "SQLiteCrossTests",
      dependencies: ["SQLiteCross"]
    ),
    .testTarget(
      name: "SQLiteCrossGRDBTests",
      dependencies: [
        .target(name: "SQLiteCrossGRDB", condition: .when(traits: ["SQLiteCrossGRDB"])),
        .product(
          name: "GRDB",
          package: "GRDB.swift",
          condition: .when(traits: ["SQLiteCrossGRDB"])
        )
      ]
    ),
    .testTarget(
      name: "SQLiteCrossStructuredQueriesTests",
      dependencies: [
        .target(
          name: "SQLiteCrossStructuredQueries",
          condition: .when(traits: ["SQLiteCrossStructuredQueries"])
        ),
        .product(
          name: "StructuredQueries",
          package: "swift-structured-queries",
          condition: .when(traits: ["SQLiteCrossStructuredQueries"])
        )
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
