#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// The FTS5 full-text module.
  ///
  /// Custom and wrapper tokenizers are not available: they need the `fts5_api` pointer, which
  /// SQLiteOrbit's library table does not expose.
  public struct FTS5 {
    /// How unicode61 tokenizers handle diacritics.
    public enum Diacritics: Sendable {
      case keep
      case removeLegacy
      case remove
    }

    public init() {}

    #if BuiltInSQLite
      // Tokenizes a query with the ascii tokenizer, through an fts5vocab table.
      static func tokenize(query string: String) throws -> [String] {
        try DatabaseQueue()
          .inDatabase { db in
            try db.execute(
              sql: "CREATE VIRTUAL TABLE document USING fts5(content, tokenize='ascii')"
            )
            try db.execute(sql: "INSERT INTO document(content) VALUES (?)", arguments: [string])
            try db.execute(
              sql: "CREATE VIRTUAL TABLE vocabulary USING fts5vocab(document, 'instance')"
            )
            return try String.fetchAll(db, sql: "SELECT term FROM vocabulary ORDER BY offset")
          }
      }
    #endif
  }

  extension FTS5: VirtualTableModule {
    public var moduleName: String { "fts5" }

    public func makeTableDefinition(configuration: VirtualTableConfiguration)
      -> FTS5TableDefinition
    {
      FTS5TableDefinition(configuration: configuration)
    }

    public func moduleArguments(for definition: FTS5TableDefinition, in db: Database) throws
      -> [String]
    {
      precondition(!definition.columns.isEmpty, "FTS5 virtual table requires at least one column.")
      var arguments = definition.columns.map { $0.isIndexed ? $0.name : $0.name + " UNINDEXED" }
      if let tokenizer = definition.tokenizer {
        let components = tokenizer.components.map(\.quotedDatabaseString).joined(separator: " ")
        arguments.append("tokenize=" + components.quotedDatabaseString)
      }
      if let contentTable = definition.synchronizedTable {
        arguments.append("content=" + contentTable.quotedDatabaseString)
        if let rowID = try db.primaryKey(contentTable).rowIDColumn {
          arguments.append("content_rowid=" + rowID.quotedDatabaseString)
        }
      } else {
        if let content = definition.rawContent {
          arguments.append("content=" + content.quotedDatabaseString)
        }
        if let rowID = definition.rawContentRowID {
          arguments.append("content_rowid=" + rowID.quotedDatabaseString)
        }
      }
      if let prefixes = definition.prefixes {
        arguments.append(
          "prefix=" + prefixes.sorted().map(String.init).joined(separator: " ").quotedDatabaseString
        )
      }
      if let columnSize = definition.columnSize { arguments.append("columnSize=\(columnSize)") }
      if let detail = definition.detail { arguments.append("detail=\(detail)") }
      return arguments
    }

    public func database(
      _ db: Database,
      didCreate tableName: String,
      using definition: FTS5TableDefinition
    ) throws {
      guard let contentTable = definition.synchronizedTable else { return }
      precondition(
        !definition.configuration.temporary,
        "Temporary external content FTS5 tables are not supported."
      )
      let rowID = try db.primaryKey(contentTable).rowIDColumn ?? "rowid"
      let fts = tableName.quotedDatabaseIdentifier
      let content = contentTable.quotedDatabaseIdentifier
      let columns = definition.columns.map(\.name)
      let ftsColumns = (["rowid"] + columns).map(\.quotedDatabaseIdentifier)
        .joined(separator: ", ")
      let newValues = ([rowID] + columns).map { "new." + $0.quotedDatabaseIdentifier }
        .joined(separator: ", ")
      let oldValues = ([rowID] + columns).map { "old." + $0.quotedDatabaseIdentifier }
        .joined(separator: ", ")
      let ifNotExists = definition.configuration.ifNotExists ? "IF NOT EXISTS " : ""
      func trigger(_ suffix: String) -> String {
        ifNotExists + "__\(tableName)_\(suffix)".quotedDatabaseIdentifier
      }
      try db.execute(
        sql: """
          CREATE TRIGGER \(trigger("ai")) AFTER INSERT ON \(content) BEGIN
              INSERT INTO \(fts)(\(ftsColumns)) VALUES (\(newValues));
          END;
          CREATE TRIGGER \(trigger("ad")) AFTER DELETE ON \(content) BEGIN
              INSERT INTO \(fts)(\(fts), \(ftsColumns)) VALUES('delete', \(oldValues));
          END;
          CREATE TRIGGER \(trigger("au")) AFTER UPDATE ON \(content) BEGIN
              INSERT INTO \(fts)(\(fts), \(ftsColumns)) VALUES('delete', \(oldValues));
              INSERT INTO \(fts)(\(ftsColumns)) VALUES (\(newValues));
          END;
          """
      )
      try db.execute(sql: "INSERT INTO \(fts)(\(fts)) VALUES('rebuild')")
    }
  }

  /// The columns and options of an FTS5 table.
  public final class FTS5TableDefinition {
    fileprivate let configuration: VirtualTableConfiguration
    fileprivate var columns: [FTS5ColumnDefinition] = []
    fileprivate var synchronizedTable: String?
    fileprivate var rawContent: String?
    fileprivate var rawContentRowID: String?

    /// The tokenizer of the table.
    public var tokenizer: FTS5TokenizerDescriptor?

    /// The external content table.
    public var content: String? {
      get { synchronizedTable ?? rawContent }
      set {
        synchronizedTable = nil
        rawContent = newValue
      }
    }

    /// The rowid column of the external content table.
    public var contentRowID: String? {
      get { synchronizedTable == nil ? rawContentRowID : nil }
      set {
        synchronizedTable = nil
        rawContentRowID = newValue
      }
    }

    public var prefixes: Set<Int>?
    public var columnSize: Int?
    public var detail: String?

    init(configuration: VirtualTableConfiguration) {
      self.configuration = configuration
    }

    /// Appends a column.
    @discardableResult
    public func column(_ name: String) -> FTS5ColumnDefinition {
      let column = FTS5ColumnDefinition(name: name)
      columns.append(column)
      return column
    }

    /// Indexes the content of a table, kept up to date with triggers.
    public func synchronize(withTable tableName: String) {
      synchronizedTable = tableName
      rawContent = nil
      rawContentRowID = nil
    }
  }

  @available(*, unavailable)
  extension FTS5TableDefinition: Sendable {}

  /// A column of an FTS5 table.
  public final class FTS5ColumnDefinition {
    fileprivate let name: String
    fileprivate var isIndexed = true

    init(name: String) {
      self.name = name
    }

    /// Excludes the column from the full-text index.
    @discardableResult
    public func notIndexed() -> Self {
      isIndexed = false
      return self
    }
  }

  @available(*, unavailable)
  extension FTS5ColumnDefinition: Sendable {}

  extension Column {
    /// The `rank` column of FTS5 tables.
    public static let rank = Column("rank")
  }

  extension Database {
    /// Drops the triggers that keep a synchronized FTS5 table up to date.
    public func dropFTS5SynchronizationTriggers(forTable tableName: String) throws {
      try execute(
        sql: ["ai", "ad", "au"]
          .map { "DROP TRIGGER IF EXISTS " + "__\(tableName)_\($0)".quotedDatabaseIdentifier + ";" }
          .joined(separator: "\n")
      )
    }

    #if BuiltInSQLite
      /// Returns a pattern restricted to the columns of a table, validated by SQLite.
      public func makeFTS5Pattern(rawPattern: String, forTable table: String) throws
        -> FTS5Pattern
      {
        try FTS5Pattern(rawPattern: rawPattern, allowedColumns: columns(in: table).map(\.name))
      }
    #endif
  }

  /// An FTS5 tokenizer, such as `.ascii()` or `.porter()`.
  public struct FTS5TokenizerDescriptor: Sendable {
    /// The tokenizer name followed by its arguments.
    public let components: [String]

    var name: String { components[0] }
    var arguments: [String] { Array(components.dropFirst()) }

    public init(components: [String]) {
      precondition(!components.isEmpty, "FTS5TokenizerDescriptor requires at least one component")
      self.components = components
    }

    private static func characterOptions(
      separators: Set<Character>,
      tokenCharacters: Set<Character>
    ) -> [String] {
      var components: [String] = []
      if !separators.isEmpty {
        components += ["separators", String(separators.sorted())]
      }
      if !tokenCharacters.isEmpty {
        components += ["tokenchars", String(tokenCharacters.sorted())]
      }
      return components
    }

    /// The `ascii` tokenizer.
    public static func ascii(
      separators: Set<Character> = [],
      tokenCharacters: Set<Character> = []
    ) -> FTS5TokenizerDescriptor {
      FTS5TokenizerDescriptor(
        components: ["ascii"]
          + characterOptions(separators: separators, tokenCharacters: tokenCharacters)
      )
    }

    /// The `porter` tokenizer, optionally wrapping another tokenizer.
    public static func porter(wrapping base: FTS5TokenizerDescriptor? = nil)
      -> FTS5TokenizerDescriptor
    {
      FTS5TokenizerDescriptor(components: ["porter"] + (base?.components ?? []))
    }

    /// The `unicode61` tokenizer.
    public static func unicode61(
      diacritics: FTS5.Diacritics = .removeLegacy,
      categories: String = "",
      separators: Set<Character> = [],
      tokenCharacters: Set<Character> = []
    ) -> FTS5TokenizerDescriptor {
      var components = ["unicode61"]
      switch diacritics {
      case .removeLegacy: break
      case .keep: components += ["remove_diacritics", "0"]
      case .remove: components += ["remove_diacritics", "2"]
      }
      if !categories.isEmpty {
        components += ["categories", categories]
      }
      components += characterOptions(separators: separators, tokenCharacters: tokenCharacters)
      return FTS5TokenizerDescriptor(components: components)
    }
  }

  /// A full-text pattern for FTS5 tables.
  public struct FTS5Pattern: Sendable {
    /// The raw pattern.
    public let rawPattern: String

    #if BuiltInSQLite
      /// Creates a pattern, validated by SQLite, optionally restricted to some columns.
      public init(rawPattern: String, allowedColumns: [String] = []) throws {
        do {
          try DatabaseQueue()
            .inDatabase { db in
              try db.create(virtualTable: "document", using: FTS5()) { t in
                for column in allowedColumns.isEmpty ? ["__grdb__"] : allowedColumns {
                  t.column(column)
                }
              }
              _ = try Row.fetchOne(
                db,
                sql: "SELECT * FROM document WHERE document MATCH ?",
                arguments: [rawPattern]
              )
            }
        } catch let error as DatabaseError {
          throw DatabaseError(resultCode: error.extendedResultCode, message: error.message)
        }
        self.rawPattern = rawPattern
      }

      private init?(tokensIn string: String, _ makePattern: ([String]) -> String) {
        guard let tokens = try? FTS5.tokenize(query: string), !tokens.isEmpty else { return nil }
        try? self.init(rawPattern: makePattern(tokens))
      }

      /// Matches any token of the string.
      public init?(matchingAnyTokenIn string: String) {
        self.init(tokensIn: string) { $0.joined(separator: " OR ") }
      }

      /// Matches all tokens of the string.
      public init?(matchingAllTokensIn string: String) {
        self.init(tokensIn: string) { $0.joined(separator: " ") }
      }

      /// Matches prefixes of all tokens of the string.
      public init?(matchingAllPrefixesIn string: String) {
        self.init(tokensIn: string) { $0.map { $0 + "*" }.joined(separator: " ") }
      }

      /// Matches the phrase made of the tokens of the string.
      public init?(matchingPhrase string: String) {
        self.init(tokensIn: string) { "\"" + $0.joined(separator: " ") + "\"" }
      }

      /// Matches the phrase at the beginning of a column.
      public init?(matchingPrefixPhrase string: String) {
        self.init(tokensIn: string) { "^\"" + $0.joined(separator: " ") + "\"" }
      }
    #endif
  }

  extension FTS5Pattern: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { rawPattern.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> FTS5Pattern? {
      #if BuiltInSQLite
        String.fromDatabaseValue(dbValue).flatMap { try? FTS5Pattern(rawPattern: $0) }
      #else
        nil
      #endif
    }
  }
#endif
