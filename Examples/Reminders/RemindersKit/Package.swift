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
  ],
  swiftLanguageModes: [.v6]
)
