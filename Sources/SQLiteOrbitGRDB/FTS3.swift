#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// The FTS3 full-text module.
  public struct FTS3 {
    /// How unicode61 tokenizers handle diacritics.
    public enum Diacritics: Sendable {
      case keep
      case removeLegacy
      case remove
    }

    public init() {}

    #if BuiltInSQLite
      /// Returns the tokens of a string, as produced by an FTS3 tokenizer.
      public static func tokenize(
        _ string: String,
        withTokenizer tokenizer: FTS3TokenizerDescriptor = .simple
      ) throws -> [String] {
        try DatabaseQueue()
          .inDatabase { db in
            let tokenizerSQL = ([tokenizer.name] + tokenizer.arguments.map { "\"\($0)\"" })
              .joined(separator: ", ")
            try db.execute(sql: "CREATE VIRTUAL TABLE tokens USING fts3tokenize(\(tokenizerSQL))")
            return try String.fetchAll(
              db,
              sql: "SELECT token FROM tokens WHERE input = ? ORDER BY position",
              arguments: [string]
            )
          }
      }
    #endif
  }

  extension FTS3: VirtualTableModule {
    public var moduleName: String { "fts3" }

    public func makeTableDefinition(configuration: VirtualTableConfiguration)
      -> FTS3TableDefinition
    {
      FTS3TableDefinition()
    }

    public func moduleArguments(for definition: FTS3TableDefinition, in db: Database) -> [String] {
      var arguments = definition.columns
      if let tokenizer = definition.tokenizer {
        arguments.append(tokenizer.moduleArgument)
      }
      return arguments
    }

    public func database(
      _ db: Database,
      didCreate tableName: String,
      using definition: FTS3TableDefinition
    ) {}
  }

  /// The columns and tokenizer of an FTS3 table.
  public final class FTS3TableDefinition {
    fileprivate var columns: [String] = []

    /// The tokenizer of the table.
    public var tokenizer: FTS3TokenizerDescriptor?

    /// Appends a column.
    public func column(_ name: String) {
      columns.append(name)
    }
  }

  @available(*, unavailable)
  extension FTS3TableDefinition: Sendable {}

  /// An FTS3 or FTS4 tokenizer, such as `.porter` or `.unicode61()`.
  public struct FTS3TokenizerDescriptor: Sendable {
    let name: String
    let arguments: [String]

    init(_ name: String, arguments: [String] = []) {
      self.name = name
      self.arguments = arguments
    }

    /// The `simple` tokenizer.
    public static let simple = FTS3TokenizerDescriptor("simple")

    /// The `porter` tokenizer.
    public static let porter = FTS3TokenizerDescriptor("porter")

    /// The `unicode61` tokenizer.
    public static func unicode61(
      diacritics: FTS3.Diacritics = .removeLegacy,
      separators: Set<Character> = [],
      tokenCharacters: Set<Character> = []
    ) -> FTS3TokenizerDescriptor {
      var arguments: [String] = []
      switch diacritics {
      case .removeLegacy: break
      case .keep: arguments.append("remove_diacritics=0")
      case .remove: arguments.append("remove_diacritics=2")
      }
      if !separators.isEmpty {
        arguments.append("separators=" + String(separators.sorted()))
      }
      if !tokenCharacters.isEmpty {
        arguments.append("tokenchars=" + String(tokenCharacters.sorted()))
      }
      return FTS3TokenizerDescriptor("unicode61", arguments: arguments)
    }

    var moduleArgument: String {
      arguments.isEmpty
        ? "tokenize=\(name)"
        : "tokenize=\(name) " + arguments.map { "\"\($0)\"" }.joined(separator: " ")
    }
  }

  /// The FTS4 full-text module.
  public struct FTS4 {
    public init() {}
  }

  extension FTS4: VirtualTableModule {
    public var moduleName: String { "fts4" }

    public func makeTableDefinition(configuration: VirtualTableConfiguration)
      -> FTS4TableDefinition
    {
      FTS4TableDefinition(configuration: configuration)
    }

    public func moduleArguments(for definition: FTS4TableDefinition, in db: Database) -> [String] {
      var arguments: [String] = []
      for column in definition.columns {
        if column.isLanguageId {
          arguments.append("languageid=\"\(column.name)\"")
        } else {
          arguments.append(column.name)
          if !column.isIndexed {
            arguments.append("notindexed=\(column.name)")
          }
        }
      }
      if let tokenizer = definition.tokenizer {
        arguments.append(tokenizer.moduleArgument)
      }
      if let content = definition.content {
        arguments.append("content=\"\(content)\"")
      }
      if let compress = definition.compress { arguments.append("compress=\"\(compress)\"") }
      if let uncompress = definition.uncompress { arguments.append("uncompress=\"\(uncompress)\"") }
      if let matchinfo = definition.matchinfo { arguments.append("matchinfo=\"\(matchinfo)\"") }
      if let prefixes = definition.prefixes {
        arguments.append(
          "prefix=\"" + prefixes.sorted().map(String.init).joined(separator: ",") + "\""
        )
      }
      return arguments
    }

    public func database(
      _ db: Database,
      didCreate tableName: String,
      using definition: FTS4TableDefinition
    ) throws {
      guard let contentTable = definition.synchronizedTable else { return }
      precondition(
        !definition.configuration.temporary,
        "Temporary external content FTS4 tables are not supported."
      )
      let rowID = try db.primaryKey(contentTable).rowIDColumn ?? "rowid"
      let fts = tableName.quotedDatabaseIdentifier
      let content = contentTable.quotedDatabaseIdentifier
      let columns = definition.columns.map(\.name)
      let ftsColumns = (["docid"] + columns).map(\.quotedDatabaseIdentifier)
        .joined(separator: ", ")
      let newValues = ([rowID] + columns).map { "new." + $0.quotedDatabaseIdentifier }
        .joined(separator: ", ")
      let oldRowID = "old." + rowID.quotedDatabaseIdentifier
      let ifNotExists = definition.configuration.ifNotExists ? "IF NOT EXISTS " : ""
      func trigger(_ suffix: String) -> String {
        ifNotExists + "__\(tableName)_\(suffix)".quotedDatabaseIdentifier
      }
      try db.execute(
        sql: """
          CREATE TRIGGER \(trigger("bu")) BEFORE UPDATE ON \(content) BEGIN
              DELETE FROM \(fts) WHERE docid=\(oldRowID);
          END;
          CREATE TRIGGER \(trigger("bd")) BEFORE DELETE ON \(content) BEGIN
              DELETE FROM \(fts) WHERE docid=\(oldRowID);
          END;
          CREATE TRIGGER \(trigger("au")) AFTER UPDATE ON \(content) BEGIN
              INSERT INTO \(fts)(\(ftsColumns)) VALUES(\(newValues));
          END;
          CREATE TRIGGER \(trigger("ai")) AFTER INSERT ON \(content) BEGIN
              INSERT INTO \(fts)(\(ftsColumns)) VALUES(\(newValues));
          END;
          """
      )
      try db.execute(sql: "INSERT INTO \(fts)(\(fts)) VALUES('rebuild')")
    }
  }

  /// The columns and options of an FTS4 table.
  public final class FTS4TableDefinition {
    fileprivate let configuration: VirtualTableConfiguration
    fileprivate var columns: [FTS4ColumnDefinition] = []
    fileprivate var synchronizedTable: String?
    private var rawContent: String?

    /// The tokenizer of the table.
    public var tokenizer: FTS3TokenizerDescriptor?

    /// The external content table.
    public var content: String? {
      get { synchronizedTable ?? rawContent }
      set {
        synchronizedTable = nil
        rawContent = newValue
      }
    }

    public var compress: String?
    public var uncompress: String?
    public var matchinfo: String?
    public var prefixes: Set<Int>?

    init(configuration: VirtualTableConfiguration) {
      self.configuration = configuration
    }

    /// Appends a column.
    @discardableResult
    public func column(_ name: String) -> FTS4ColumnDefinition {
      let column = FTS4ColumnDefinition(name: name)
      columns.append(column)
      return column
    }

    /// Indexes the content of a table, kept up to date with triggers.
    public func synchronize(withTable tableName: String) {
      synchronizedTable = tableName
      rawContent = nil
    }
  }

  @available(*, unavailable)
  extension FTS4TableDefinition: Sendable {}

  /// A column of an FTS4 table.
  public final class FTS4ColumnDefinition {
    fileprivate let name: String
    fileprivate var isIndexed = true
    fileprivate var isLanguageId = false

    init(name: String) {
      self.name = name
    }

    /// Excludes the column from the full-text index.
    @discardableResult
    public func notIndexed() -> Self {
      isIndexed = false
      return self
    }

    /// Uses the column as the language id.
    @discardableResult
    public func asLanguageId() -> Self {
      isLanguageId = true
      return self
    }
  }

  @available(*, unavailable)
  extension FTS4ColumnDefinition: Sendable {}

  extension Database {
    /// Drops the triggers that keep a synchronized FTS4 table up to date.
    public func dropFTS4SynchronizationTriggers(forTable tableName: String) throws {
      try execute(
        sql: ["bu", "bd", "au", "ai"]
          .map { "DROP TRIGGER IF EXISTS " + "__\(tableName)_\($0)".quotedDatabaseIdentifier + ";" }
          .joined(separator: "\n")
      )
    }
  }

  /// A full-text pattern for FTS3 and FTS4 tables.
  public struct FTS3Pattern: Sendable {
    /// The raw pattern.
    public let rawPattern: String

    #if BuiltInSQLite
      /// Creates a pattern, validated by SQLite.
      public init(rawPattern: String) throws {
        do {
          try DatabaseQueue()
            .inDatabase { db in
              try db.execute(
                literal: """
                  CREATE VIRTUAL TABLE documents USING fts3();
                  SELECT * FROM documents WHERE content MATCH \(rawPattern);
                  """
              )
            }
        } catch let error as DatabaseError {
          throw DatabaseError(resultCode: error.extendedResultCode, message: error.message)
        }
        self.rawPattern = rawPattern
      }

      private init?(tokensIn string: String, _ makePattern: ([String]) -> String) {
        guard let tokens = try? FTS3.tokenize(string), !tokens.isEmpty else { return nil }
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
    #endif
  }

  extension FTS3Pattern: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { rawPattern.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> FTS3Pattern? {
      #if BuiltInSQLite
        String.fromDatabaseValue(dbValue).flatMap { try? FTS3Pattern(rawPattern: $0) }
      #else
        nil
      #endif
    }
  }

  extension TableRequest where Self: FilteredRequest {
    /// Filters rows that match a full-text pattern; a nil pattern matches nothing.
    public func matching(_ pattern: FTS3Pattern?) -> Self {
      guard let pattern else { return none() }
      let alias = TableAlias()
      return _aliased(alias).filter(SQLExpression.tableMatch(alias, pattern.sqlExpression))
    }

    /// Filters rows that match a full-text pattern; a nil pattern matches nothing.
    public func matching(_ pattern: FTS5Pattern?) -> Self {
      guard let pattern else { return none() }
      let alias = TableAlias()
      return _aliased(alias).filter(SQLExpression.tableMatch(alias, pattern.sqlExpression))
    }
  }

  extension TableRecord {
    /// A request for rows that match a full-text pattern.
    public static func matching(_ pattern: FTS3Pattern?) -> QueryInterfaceRequest<Self> {
      all().matching(pattern)
    }

    /// A request for rows that match a full-text pattern.
    public static func matching(_ pattern: FTS5Pattern?) -> QueryInterfaceRequest<Self> {
      all().matching(pattern)
    }
  }

  extension ColumnExpression {
    /// `column MATCH pattern`.
    public func match(_ pattern: FTS3Pattern?) -> SQLExpression {
      .binary("MATCH", sqlExpression, pattern?.sqlExpression ?? .null)
    }

    /// `column MATCH pattern`.
    public func match(_ pattern: FTS5Pattern) -> SQLExpression {
      .binary("MATCH", sqlExpression, pattern.sqlExpression)
    }
  }
#endif
