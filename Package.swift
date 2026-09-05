// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "sqlite-orbit",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
    .tvOS(.v16),
    .watchOS(.v9),
    .visionOS(.v1)
  ],
  products: [
    .library(name: "SQLiteOrbit", targets: ["SQLiteOrbit"])
  ],
  traits: [
    .default(enabledTraits: ["SystemSQLite"]),
    .trait(
      name: "SystemSQLite",
      description: "Links the platform SQLite and vends `SQLiteLibrary.system`."
    ),
    .trait(
      name: "SQLCipher",
      description:
        "Links SQLCipher and vends `SQLiteLibrary.sqlCipher`, which opens encrypted databases. "
        + "Mutually exclusive with `SystemSQLite`, which exports the same `sqlite3_*` symbols."
    )
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-structured-queries", from: "0.39.0"),
    .package(url: "https://github.com/skiptools/swift-sqlcipher", from: "1.12.0")
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite3",
      path: "Sources/CSQLite3",
      pkgConfig: "sqlite3",
      providers: [
        .apt(["libsqlite3-dev"]),
        .yum(["sqlite-devel"]),
        .brew(["sqlite3"])
      ]
    ),
    .target(
      name: "SQLiteOrbit",
      dependencies: [
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
        .target(
          name: "CSQLite3",
          condition: .when(traits: ["SystemSQLite"])
        ),
        .product(
          name: "SQLCipher",
          package: "swift-sqlcipher",
          condition: .when(traits: ["SQLCipher"])
        )
      ],
      cSettings: [
        // SQLCipher declares `sqlite3_key_v2` and `sqlite3_rekey_v2` behind this, and a
        // dependency's own C settings do not reach the clang importer of a target importing it.
        // Without this the codec entry points are simply invisible.
        .define("SQLITE_HAS_CODEC", .when(traits: ["SQLCipher"]))
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("SuppressedAssociatedTypes"),
        // Every trait that links a SQLite of its own defines this, so that code needing only
        // "some build is available" does not have to name each one.
        .define("BuiltInSQLite", .when(traits: ["SystemSQLite"])),
        .define("BuiltInSQLite", .when(traits: ["SQLCipher"]))
      ]
    ),
    .testTarget(
      name: "SQLiteOrbitTests",
      dependencies: [
        "SQLiteOrbit",
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
        .target(
          name: "CSQLite3",
          condition: .when(traits: ["SystemSQLite"])
        ),
        .product(
          name: "SQLCipher",
          package: "swift-sqlcipher",
          condition: .when(traits: ["SQLCipher"])
        )
      ],
      cSettings: [
        // SQLCipher declares `sqlite3_key_v2` and `sqlite3_rekey_v2` behind this, and a
        // dependency's own C settings do not reach the clang importer of a target importing it.
        // Without this the codec entry points are simply invisible.
        .define("SQLITE_HAS_CODEC", .when(traits: ["SQLCipher"]))
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("SuppressedAssociatedTypes"),
        // Every trait that links a SQLite of its own defines this, so that code needing only
        // "some build is available" does not have to name each one.
        .define("BuiltInSQLite", .when(traits: ["SystemSQLite"])),
        .define("BuiltInSQLite", .when(traits: ["SQLCipher"]))
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
