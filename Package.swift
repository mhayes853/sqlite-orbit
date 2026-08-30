// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "swift-sqlite-cross",
  platforms: [
    .macOS(.v10_15),
    .iOS(.v13),
    .tvOS(.v13),
    .watchOS(.v7),
    .visionOS(.v1)
  ],
  products: [
    .library(name: "SQLiteCross", targets: ["SQLiteCross"])
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1")
  ],
  targets: [
    .target(
      name: "SQLiteCross",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ]
    ),
    .testTarget(
      name: "SQLiteCrossTests",
      dependencies: ["SQLiteCross"]
    )
  ],
  swiftLanguageModes: [.v6]
)
