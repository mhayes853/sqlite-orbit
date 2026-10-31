#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// A foreign key that defines an association between two tables.
  ///
  /// When destination columns are omitted, they are the primary key of the destination table.
  public struct ForeignKey: Equatable, Sendable {
    var originColumns: [String]
    var destinationColumns: [String]?

    public init(_ originColumns: [String], to destinationColumns: [String]? = nil) {
      self.originColumns = originColumns
      self.destinationColumns = destinationColumns
    }

    public init(
      _ originColumns: [any ColumnExpression],
      to destinationColumns: [any ColumnExpression]? = nil
    ) {
      self.init(originColumns.map(\.name), to: destinationColumns?.map(\.name))
    }
  }

  /// Pairs of joined columns, from the left table to the right table.
  struct JoinMapping: Sendable {
    var pairs: [(left: String, right: String)]

    var leftColumns: [String] { pairs.map(\.left) }
    var rightColumns: [String] { pairs.map(\.right) }

    /// `right.b = left.a AND ...`
    func joinExpression(left: TableAliasBase, right: TableAliasBase) -> SQLExpression {
      .associative(
        .and,
        pairs.map { .equal(.qualifiedColumn($0.right, right), .qualifiedColumn($0.left, left)) }
      )
    }
  }

  /// A foreign key condition between the two sides of an association.
  struct SQLForeignKeyCondition: Equatable, Sendable {
    var destinationTable: String
    var foreignKey: ForeignKey?
    /// Whether the foreign key origin is the left side of the join (belongsTo).
    var originIsLeft: Bool

    func reversed(to destinationTable: String) -> SQLForeignKeyCondition {
      SQLForeignKeyCondition(
        destinationTable: destinationTable,
        foreignKey: foreignKey,
        originIsLeft: !originIsLeft
      )
    }

    func joinMapping(_ db: Database, from leftTable: String) throws -> JoinMapping {
      let origin = originIsLeft ? leftTable : destinationTable
      let destination = originIsLeft ? destinationTable : leftTable
      let mapping = try foreignKeyMapping(db, origin: origin, destination: destination)
      return JoinMapping(
        pairs: mapping.map {
          originIsLeft ? ($0.origin, $0.destination) : ($0.destination, $0.origin)
        }
      )
    }

    private func foreignKeyMapping(_ db: Database, origin: String, destination: String) throws
      -> [(origin: String, destination: String)]
    {
      let originColumns = foreignKey?.originColumns
      let destinationColumns = foreignKey?.destinationColumns
      if let originColumns, let destinationColumns {
        guard originColumns.count == destinationColumns.count else {
          throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Number of columns don't match")
        }
        return Array(zip(originColumns, destinationColumns))
      }
      if try db.tableExists(origin) {
        let candidates = try db.foreignKeys(on: origin)
          .filter { key in
            guard key.destinationTable.lowercased() == destination.lowercased() else {
              return false
            }
            if let originColumns,
              Set(originColumns.map { $0.lowercased() })
                != Set(key.originColumns.map { $0.lowercased() })
            {
              return false
            }
            if let destinationColumns,
              Set(destinationColumns.map { $0.lowercased() })
                != Set(key.destinationColumns.map { $0.lowercased() })
            {
              return false
            }
            return true
          }
        if let key = candidates.first {
          guard candidates.count == 1 else {
            throw DatabaseError(
              resultCode: .SQLITE_MISUSE,
              message:
                "Ambiguous foreign key from '\(origin)' to '\(destination)'. To fix this error, provide an explicit `ForeignKey` in the association definition."
            )
          }
          return Array(zip(key.originColumns, key.destinationColumns))
        }
      } else if originColumns == nil {
        throw inferenceError(origin, destination)
      }
      if let originColumns, try db.tableExists(destination) {
        let destinationColumns = try db.primaryKey(destination).columns
        if originColumns.count == destinationColumns.count {
          return Array(zip(originColumns, destinationColumns))
        }
      }
      throw inferenceError(origin, destination)
    }

    private func inferenceError(_ origin: String, _ destination: String) -> DatabaseError {
      DatabaseError(
        resultCode: .SQLITE_MISUSE,
        message:
          "Could not infer foreign key from '\(origin)' to '\(destination)'. To fix this error, provide an explicit `ForeignKey` in the association definition."
      )
    }
  }
#endif
