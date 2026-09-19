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
    .library(name: "RemindersIntents", targets: ["RemindersIntents"]),
  ],
  dependencies: [
    .package(name: "sqlite-orbit", path: "../../..")
  ],
  targets: [
    .target(
      name: "RemindersData",
      dependencies: [
        .product(name: "SQLiteOrbit", package: "sqlite-orbit")
      ]
    ),
    .target(
      name: "RemindersNotifications",
      dependencies: ["RemindersData"]
    ),
    .target(
      name: "RemindersUI",
      dependencies: ["RemindersData"]
    ),
    .target(
      name: "RemindersIntents",
      dependencies: [
        "RemindersData",
        "RemindersNotifications",
        "RemindersUI",
        .product(name: "SQLiteOrbit", package: "sqlite-orbit"),
      ]
    ),
    .testTarget(
      name: "RemindersDataTests",
      dependencies: ["RemindersData"]
    ),
    .testTarget(
      name: "RemindersNotificationsTests",
      dependencies: ["RemindersData", "RemindersNotifications"]
    ),
    .testTarget(
      name: "RemindersUITests",
      dependencies: ["RemindersUI"]
    ),
    .testTarget(
      name: "RemindersIntentsTests",
      dependencies: [
        "RemindersData",
        "RemindersIntents",
        "RemindersNotifications",
        .product(name: "SQLiteOrbit", package: "sqlite-orbit"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
