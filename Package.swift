// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

// ViewInspector renders a SwiftUI view in a hosting controller, so it only exists where SwiftUI
// does. A manifest is compiled and run on the host, which is what keeps a Linux build from
// resolving a package it could never build.
#if canImport(Darwin)
  let swiftUITestPackages: [Package.Dependency] = [
    .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.3")
  ]
  let swiftUITestDependencies: [Target.Dependency] = [
    .product(name: "ViewInspector", package: "ViewInspector")
  ]
#else
  let swiftUITestPackages: [Package.Dependency] = []
  let swiftUITestDependencies: [Target.Dependency] = []
#endif

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
    ),
    .trait(
      name: "Turso",
      description:
        "Links the local Rust Turso engine and vends `SQLiteLibrary.turso`. Mutually exclusive "
        + "with the other SQLite traits, which export the same `sqlite3_*` symbols."
    )
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-structured-queries", from: "0.39.0"),
    .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.7.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"605.0.0"),
    .package(url: "https://github.com/skiptools/swift-sqlcipher", from: "1.12.0")
  ] + swiftUITestPackages,
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
    .systemLibrary(
      name: "TursoSQLite3",
      path: "Sources/TursoSQLite3"
    ),
    .target(
      name: "SQLiteOrbit",
      dependencies: [
        "SQLiteOrbitMacros",
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
        .target(
          name: "CSQLite3",
          condition: .when(traits: ["SystemSQLite"])
        ),
        .product(
          name: "SQLCipher",
          package: "swift-sqlcipher",
          condition: .when(traits: ["SQLCipher"])
        ),
        .target(
          name: "TursoSQLite3",
          condition: .when(traits: ["Turso"])
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
        .define("BuiltInSQLite", .when(traits: ["SQLCipher"])),
        .define("BuiltInSQLite", .when(traits: ["Turso"]))
      ],
      linkerSettings: [
        // Rust's standard library uses the platform math library. This is already implicit on
        // Apple platforms, while Linux consumers of the Turso static artifact must name it.
        .linkedLibrary("m", .when(platforms: [.linux]))
      ]
    ),
    .macro(
      name: "SQLiteOrbitMacros",
      dependencies: [
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax")
      ]
    ),
    .testTarget(
      name: "SQLiteOrbitMacrosTests",
      dependencies: [
        "SQLiteOrbitMacros",
        .product(name: "MacroTesting", package: "swift-macro-testing")
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
        ),
        .target(
          name: "TursoSQLite3",
          condition: .when(traits: ["Turso"])
        )
      ] + swiftUITestDependencies,
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
        .define("BuiltInSQLite", .when(traits: ["SQLCipher"])),
        .define("BuiltInSQLite", .when(traits: ["Turso"]))
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
