// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "RemindersKit",
  platforms: [
    .iOS(.v26),
    .macOS(.v26),
  ],
  products: [
    .library(
      name: "RemindersKit",
      targets: ["RemindersData", "RemindersNotifications", "RemindersUI"]
    ),
  ],
  dependencies: [
    .package(name: "sqlite-orbit", path: "../../.."),
    .package(url: "https://github.com/pointfreeco/swift-structured-queries", from: "0.39.0"),
  ],
  targets: [
    .target(
      name: "RemindersData",
      dependencies: [
        .product(name: "SQLiteOrbit", package: "sqlite-orbit"),
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
      ]
    ),
    .target(
      name: "RemindersNotifications",
      dependencies: [
        "RemindersData",
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
      ]
    ),
    .target(
      name: "RemindersUI",
      dependencies: ["RemindersData"]
    ),
    .testTarget(
      name: "RemindersDataTests",
      dependencies: [
        "RemindersData",
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
      ]
    ),
    .testTarget(
      name: "RemindersNotificationsTests",
      dependencies: [
        "RemindersData",
        "RemindersNotifications",
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
      ]
    ),
    .testTarget(
      name: "RemindersUITests",
      dependencies: ["RemindersUI"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
