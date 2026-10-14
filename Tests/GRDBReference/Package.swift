// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "GRDBReference",
  dependencies: [.package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")],
  targets: [.testTarget(name: "GRDBReferenceTests", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], path: "Sources")]
)
