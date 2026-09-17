// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "RemindersData",
  platforms: [
    .iOS(.v17),
    .macOS(.v13),
  ],
  products: [
    .library(name: "RemindersData", targets: ["RemindersData"])
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
    .testTarget(
      name: "RemindersDataTests",
      dependencies: ["RemindersData"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
