// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

// ViewInspector renders a SwiftUI view in a hosting controller, so it only exists where SwiftUI
// does. A manifest is compiled and run on the host, which is what keeps a Linux build from
// resolving a package it could never build.
#if canImport(Darwin)
  let swiftUITestPackages: [Package.Dependency] = [
    // 0.10.4's manifest declares tools version 5.9 but names `.visionOS(.v2)`, which only exists
    // from PackageDescription 6.0, so it fails to load and resolution stops rather than falling
    // back to an earlier release.
    .package(url: "https://github.com/nalexn/ViewInspector", "0.10.3"..<"0.10.4")
  ]
  let swiftUITestDependencies: [Target.Dependency] = [
    .product(name: "ViewInspector", package: "ViewInspector")
  ]
  // Apple-platform builds must use the SQLite library in the active SDK. Consulting pkg-config
  // on the macOS host can otherwise inject a Homebrew macOS dylib into an iOS simulator build.
  let sqlitePkgConfig: String? = nil
  let sqliteProviders: [SystemPackageProvider]? = nil
#else
  let swiftUITestPackages: [Package.Dependency] = []
  let swiftUITestDependencies: [Target.Dependency] = []
  let sqlitePkgConfig: String? = "sqlite3"
  let sqliteProviders: [SystemPackageProvider]? = [
    .apt(["libsqlite3-dev"]),
    .yum(["sqlite-devel"]),
    .brew(["sqlite3"])
  ]
#endif

// The published Turso artifact has Apple and Linux slices only. SwiftPM resolves binary targets
// even when their trait is disabled, so omit it from manifests evaluated on Windows.
#if os(Windows)
  let tursoTargets: [Target] = []
  let tursoDependencies: [Target.Dependency] = []
#else
  let tursoTargets: [Target] = [
    .binaryTarget(
      name: "TursoSQLite3",
      url:
        "https://github.com/mhayes853/sqlite-orbit/releases/download/turso-0.8.0-pre.11/TursoSQLite3-0.8.0-pre.11-r5.artifactbundleindex",
      checksum: "0f4843d061b9bce33e265a8016cb2576ca1207a4748282ed2465d24b880d70ee"
    )
  ]
  let tursoDependencies: [Target.Dependency] = [
    .target(name: "TursoSQLite3", condition: .when(traits: ["Turso"]))
  ]
#endif

let packageTarget0: Target = .systemLibrary(
  name: "CSQLite3",
  path: "Sources/CSQLite3",
  pkgConfig: sqlitePkgConfig,
  providers: sqliteProviders
)

// Swift's Glibc module leaves out `sys/epoll.h` and `sys/eventfd.h`, which the Unix datagram
// transport's thread waits with on Linux and Android, so this header-only module imports them.
let linuxEventsTarget: Target = .systemLibrary(
  name: "CLinuxEvents",
  path: "Sources/CLinuxEvents"
)

let packageTarget1: Target = .target(
  name: "SQLiteOrbit",
  dependencies: [
    "SQLiteOrbitMacros",
    .target(name: "CSQLiteOrbitVec", condition: .when(traits: ["Vectors"])),
    .product(name: "CSQLiteVec", package: "sqlite-vec-data", condition: .when(traits: ["Vectors"])),
    .product(
      name: "StructuredQueriesSQLiteVecCore",
      package: "sqlite-vec-data",
      condition: .when(traits: ["Vectors"])
    ),
    .product(
      name: "StructuredQueriesSQLite",
      package: "swift-structured-queries",
      condition: .when(traits: ["StructuredQueries"])
    ),
    .target(name: "_SQLiteOrbitFoundation", condition: .when(traits: ["Foundation"])),
    .target(name: "CLinuxEvents", condition: .when(platforms: [.linux, .android])),
    .target(
      name: "CSQLite3",
      condition: .when(traits: ["SystemSQLite"])
    ),
    .product(
      name: "SQLCipher",
      package: "swift-sqlcipher",
      condition: .when(traits: ["SQLCipher"])
    ),
    .product(
      name: "Dependencies",
      package: "swift-dependencies",
      condition: .when(traits: ["Dependencies"])
    ),
    .product(name: "UUIDV7", package: "swift-uuidv7", condition: .when(traits: ["UUIDV7"])),
    .product(name: "Tagged", package: "swift-tagged", condition: .when(traits: ["Tagged"])),
  ] + tursoDependencies,
  cSettings: [
    // SQLCipher declares `sqlite3_key_v2` and `sqlite3_rekey_v2` behind this, and a
    // dependency's own C settings do not reach the clang importer of a target importing it.
    // Without this the codec entry points are simply invisible.
    .define("SQLITE_HAS_CODEC", .when(traits: ["SQLCipher"]))
  ],
  swiftSettings: [
    .enableExperimentalFeature("Lifetimes"),
    .enableExperimentalFeature("SuppressedAssociatedTypes"),
    // Swift's WASILibc module does not import `pthread.h`, so the pthread functions the
    // connection executor needs are declared by hand there.
    .enableExperimentalFeature("Extern", .when(platforms: [.wasi])),
    // Every trait that links a SQLite of its own defines this, so that code needing only
    // "some build is available" does not have to name each one.
    .define("BuiltInSQLite", .when(traits: ["SystemSQLite"])),
    .define("BuiltInSQLite", .when(traits: ["SQLCipher"])),
    .define("BuiltInSQLite", .when(traits: ["Turso"])),
    .define("Dependencies", .when(traits: ["Dependencies"])),
    .define("Foundation", .when(traits: ["Foundation"])),
    .define("Vectors", .when(traits: ["Vectors"])),
    .define("StructuredQueries", .when(traits: ["StructuredQueries"])),
    .define("UUIDV7", .when(traits: ["UUIDV7"])),
    .define("Tagged", .when(traits: ["Tagged"]))
  ],
  linkerSettings: [
    // Rust's standard library uses the platform math library. This is already implicit on
    // Apple platforms, while Linux consumers of the Turso static artifact must name it.
    .linkedLibrary("m", .when(platforms: [.linux]))
  ]
)

// Imports FoundationEssentials where the toolchain has it, and all of Foundation elsewhere, so the
// `Foundation` trait never links more than the package uses.
let foundationTarget: Target = .target(
  name: "_SQLiteOrbitFoundation",
  path: "Sources/_SQLiteOrbitFoundation"
)

// Keep Vec's platform SQLite headers out of Swift modules importing a custom SQLite build.
let sqliteVecTarget: Target = .target(
  name: "CSQLiteOrbitVec",
  dependencies: [
    .product(name: "CSQLiteVec", package: "sqlite-vec-data", condition: .when(traits: ["Vectors"]))
  ],
  cSettings: [.define("SQLITE_ORBIT_VEC", .when(traits: ["Vectors"]))]
)

let packageTarget2: Target = .target(
  name: "SQLiteOrbitTestSupport",
  dependencies: ["SQLiteOrbit"]
)

let packageTarget3: Target = .macro(
  name: "SQLiteOrbitMacros",
  dependencies: [
    .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
    .product(name: "SwiftDiagnostics", package: "swift-syntax"),
    .product(name: "SwiftSyntax", package: "swift-syntax"),
    .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
    .product(name: "SwiftSyntaxMacros", package: "swift-syntax")
  ]
)

let packageTarget4: Target = .testTarget(
  name: "SQLiteOrbitMacrosTests",
  dependencies: [
    "SQLiteOrbitMacros",
    .product(name: "MacroTesting", package: "swift-macro-testing"),
    .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax")
  ]
)

let packageTarget5: Target = .testTarget(
  name: "SQLiteOrbitTests",
  dependencies: [
    "SQLiteOrbit",
    "SQLiteOrbitTestSupport",
    .product(
      name: "StructuredQueriesSQLite",
      package: "swift-structured-queries",
      condition: .when(traits: ["StructuredQueries"])
    ),
    .target(name: "_SQLiteOrbitFoundation", condition: .when(traits: ["Foundation"])),
    .product(
      name: "Dependencies",
      package: "swift-dependencies",
      condition: .when(traits: ["Dependencies"])
    ),
    .product(name: "UUIDV7", package: "swift-uuidv7", condition: .when(traits: ["UUIDV7"])),
    .product(name: "Tagged", package: "swift-tagged", condition: .when(traits: ["Tagged"])),
    .target(
      name: "CSQLite3",
      condition: .when(traits: ["SystemSQLite"])
    ),
    .product(
      name: "SQLCipher",
      package: "swift-sqlcipher",
      condition: .when(traits: ["SQLCipher"])
    ),
  ] + swiftUITestDependencies + tursoDependencies,
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
    .define("BuiltInSQLite", .when(traits: ["Turso"])),
    .define("Dependencies", .when(traits: ["Dependencies"])),
    .define("Foundation", .when(traits: ["Foundation"])),
    .define("Vectors", .when(traits: ["Vectors"])),
    .define("StructuredQueries", .when(traits: ["StructuredQueries"])),
    .define("UUIDV7", .when(traits: ["UUIDV7"])),
    .define("Tagged", .when(traits: ["Tagged"]))
  ]
)

let packageTargets: [Target] = [
  packageTarget0,
  linuxEventsTarget,
  foundationTarget,
  sqliteVecTarget,
  packageTarget1,
  packageTarget2,
  packageTarget3,
  packageTarget4,
  packageTarget5,
] + tursoTargets

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
    .library(name: "SQLiteOrbit", targets: ["SQLiteOrbit"]),
    .library(name: "SQLiteOrbitTestSupport", targets: ["SQLiteOrbitTestSupport"])
  ],
  traits: [
    .default(enabledTraits: ["SystemSQLite", "StructuredQueries", "Foundation"]),
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
    ),
    .trait(
      name: "Foundation",
      description:
        "Adds `Date`, `UUID`, `Data`, and `URL` conveniences, using FoundationEssentials where "
        + "the toolchain provides it."
    ),
    .trait(
      name: "StructuredQueries",
      description:
        "Adds the type-safe query layer from swift-structured-queries on top of raw `SQL`.",
      enabledTraits: ["Foundation"]
    ),
    .trait(
      name: "Vectors",
      description:
        "Includes SQLite Vec and initializes it automatically on supported SQLite connections."
    ),
    .trait(
      name: "Dependencies",
      description:
        "Integrates `OrbitDefaultDatabase` with the swift-dependencies package."
    ),
    .trait(
      name: "UUIDV7",
      description:
        "Conforms swift-uuidv7's `UUIDV7` to the database value conversion protocols, and adds "
        + "`OrbitBinaryUUIDV7` and `OrbitUppercaseUUIDV7`."
    ),
    .trait(
      name: "Tagged",
      description:
        "Conforms swift-tagged's `Tagged` to the database value conversion protocols."
    )
  ],
  dependencies: [
    .package(
      url: "https://github.com/mhayes853/sqlite-vec-data",
      revision: "f980c99e337ff7c3aff250558d038ee2b149f47e"
    ),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.12.0"),
    // SwiftPM can only condition a dependency's trait on one of this package's traits, not on two
    // together. swift-uuidv7's Structured Queries and Tagged traits follow `StructuredQueries` and
    // `Tagged`, but its module is only built under `UUIDV7`, so each takes effect only with
    // `UUIDV7` on as well. Likewise, Structured Queries' `Tagged` trait follows `Tagged`, but only
    // matters with `StructuredQueries` on.
    .package(
      url: "https://github.com/pointfreeco/swift-structured-queries",
      from: "0.39.0",
      traits: [.trait(name: "Tagged", condition: .when(traits: ["Tagged"]))]
    ),
    .package(
      url: "https://github.com/mhayes853/swift-uuidv7",
      from: "0.3.0",
      traits: [
        .trait(
          name: "SwiftUUIDV7StructuredQueries",
          condition: .when(traits: ["StructuredQueries"])
        ),
        .trait(name: "SwiftUUIDV7Tagged", condition: .when(traits: ["Tagged"]))
      ]
    ),
    .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
    .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.7.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"605.0.0"),
    .package(url: "https://github.com/skiptools/swift-sqlcipher", from: "1.12.0")
  ] + swiftUITestPackages,
  targets: packageTargets,
  swiftLanguageModes: [.v6]
)
