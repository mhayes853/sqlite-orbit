// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "RemindersKit",
  platforms: [
    .iOS(.v17),
    .macOS(.v13),
  ],
  products: [
    .library(name: "RemindersKit", targets: ["RemindersData"]),
    .library(name: "RemindersIntents", targets: ["RemindersIntents"]),
  ],
  dependencies: [
    .package(name: "sqlite-orbit", path: "../..")
  ],
  targets: [
    .target(
      name: "RemindersData",
      dependencies: [
        .product(name: "SQLiteOrbit", package: "sqlite-orbit")
      ]
    ),
    .target(
      name: "RemindersIntents",
      dependencies: [
        "RemindersData",
        .product(name: "SQLiteOrbit", package: "sqlite-orbit"),
      ]
    ),
    .testTarget(
      name: "RemindersDataTests",
      dependencies: ["RemindersData"]
    ),
    .testTarget(
      name: "RemindersIntentsTests",
      dependencies: [
        "RemindersData",
        "RemindersIntents",
        .product(name: "SQLiteOrbit", package: "sqlite-orbit"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
