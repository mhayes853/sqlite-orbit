#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// A virtual table module, such as FTS4, that `Database.create(virtualTable:using:)` uses.
  public protocol VirtualTableModule {
    associatedtype TableDefinition

    /// The name of the module, as in `CREATE VIRTUAL TABLE ... USING name(...)`.
    var moduleName: String { get }

    /// Returns a new table definition, configured by the closure given to `create(virtualTable:)`.
    func makeTableDefinition(configuration: VirtualTableConfiguration) -> TableDefinition

    /// The module arguments of the table definition.
    func moduleArguments(for definition: TableDefinition, in db: Database) throws -> [String]

    /// Runs after the virtual table was created, in the same savepoint.
    func database(_ db: Database, didCreate tableName: String, using definition: TableDefinition)
      throws
  }

  /// How a virtual table is created.
  public struct VirtualTableConfiguration {
    var ifNotExists: Bool
    var temporary: Bool
  }

  /// Options for `Database.create(virtualTable:options:using:)`.
  public struct VirtualTableOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `CREATE VIRTUAL TABLE IF NOT EXISTS`.
    public static let ifNotExists = VirtualTableOptions(rawValue: 1 << 0)

    /// Creates the table in the temp schema.
    public static let temporary = VirtualTableOptions(rawValue: 1 << 1)
  }

  extension String {
    /// The string quoted as an SQL identifier, such as `"name"`.
    public var quotedDatabaseIdentifier: String {
      "\"" + replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // The string quoted as an SQL string literal, such as `'it''s'`.
    var quotedDatabaseString: String {
      "'" + replacingOccurrences(of: "'", with: "''") + "'"
    }
  }

  extension Database {
    private func virtualTablePrefix(_ name: String, options: VirtualTableOptions) -> String {
      var chunks = ["CREATE VIRTUAL TABLE"]
      if options.contains(.ifNotExists) { chunks.append("IF NOT EXISTS") }
      chunks.append(
        options.contains(.temporary)
          ? "temp." + name.quotedDatabaseIdentifier : name.quotedDatabaseIdentifier
      )
      chunks.append("USING")
      return chunks.joined(separator: " ")
    }

    /// Creates a virtual table with a module given as SQL, such as `fts3(content)`.
    public func create(
      virtualTable name: String,
      options: VirtualTableOptions = [],
      using module: String
    ) throws {
      try execute(sql: virtualTablePrefix(name, options: options) + " " + module)
    }

    /// Creates a virtual table defined by a module, such as FTS4 or FTS5.
    public func create<Module: VirtualTableModule>(
      virtualTable tableName: String,
      options: VirtualTableOptions = [],
      using module: Module,
      _ body: ((Module.TableDefinition) throws -> Void)? = nil
    ) throws {
      let configuration = VirtualTableConfiguration(
        ifNotExists: options.contains(.ifNotExists),
        temporary: options.contains(.temporary)
      )
      let definition = module.makeTableDefinition(configuration: configuration)
      try body?(definition)
      let arguments = try module.moduleArguments(for: definition, in: self)
      let moduleSQL =
        arguments.isEmpty
        ? module.moduleName : module.moduleName + "(" + arguments.joined(separator: ", ") + ")"
      let sql = virtualTablePrefix(tableName, options: options) + " " + moduleSQL
      try inSavepoint {
        try execute(sql: sql)
        try module.database(self, didCreate: tableName, using: definition)
        return .commit
      }
    }

    @_disfavoredOverload
    public func create(virtualTable name: String, ifNotExists: Bool = false, using module: String)
      throws
    {
      try create(virtualTable: name, options: ifNotExists ? .ifNotExists : [], using: module)
    }

    @_disfavoredOverload
    public func create<Module: VirtualTableModule>(
      virtualTable tableName: String,
      ifNotExists: Bool = false,
      using module: Module,
      _ body: ((Module.TableDefinition) throws -> Void)? = nil
    ) throws {
      try create(
        virtualTable: tableName,
        options: ifNotExists ? .ifNotExists : [],
        using: module,
        body
      )
    }
  }
#endif
