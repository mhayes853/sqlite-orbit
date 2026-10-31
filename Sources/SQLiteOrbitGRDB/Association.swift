#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  // MARK: - Association model

  /// The key under which an association's rows are decoded, and how it is inflected.
  enum SQLAssociationKey: Sendable {
    case inflected(String)
    case fixedSingular(String)
    case fixedPlural(String)
    case fixed(String)

    var baseName: String {
      get {
        switch self {
        case .inflected(let name), .fixedSingular(let name), .fixedPlural(let name),
          .fixed(let name):
          return name
        }
      }
      set {
        switch self {
        case .inflected: self = .inflected(newValue)
        case .fixedSingular: self = .fixedSingular(newValue)
        case .fixedPlural: self = .fixedPlural(newValue)
        case .fixed: self = .fixed(newValue)
        }
      }
    }

    func name(singular: Bool) -> String {
      switch self {
      case .inflected(let name): return singular ? name.singularized : name.pluralized
      case .fixedSingular(let name): return singular ? name : name.pluralized
      case .fixedPlural(let name): return singular ? name.singularized : name
      case .fixed(let name): return name
      }
    }
  }

  enum SQLAssociationCardinality: Sendable {
    case toOne, toMany

    var isSingular: Bool { self == .toOne }
  }

  /// One step of an association, from the previous table to `relation`.
  struct SQLAssociationStep: Sendable {
    var key: SQLAssociationKey
    var condition: SQLAssociationCondition
    var relation: SQLRelation
    var cardinality: SQLAssociationCardinality

    var keyName: String { key.name(singular: cardinality.isSingular) }
  }

  /// The implementation of an association: a chain of steps from the origin to the destination.
  public struct _SQLAssociation: Sendable {
    private(set) var steps: [SQLAssociationStep]

    init(steps: [SQLAssociationStep]) {
      precondition(!steps.isEmpty)
      self.steps = steps
    }

    init(
      key: SQLAssociationKey,
      condition: SQLAssociationCondition,
      relation: SQLRelation,
      cardinality: SQLAssociationCardinality
    ) {
      self.init(
        steps: [
          SQLAssociationStep(
            key: key,
            condition: condition,
            relation: relation,
            cardinality: cardinality
          )
        ]
      )
    }

    var keyPath: [String] { steps.map(\.keyName) }

    var destination: SQLAssociationStep {
      get { steps[steps.count - 1] }
      set { steps[steps.count - 1] = newValue }
    }

    var pivot: SQLAssociationStep {
      get { steps[0] }
      set { steps[0] = newValue }
    }

    func forDestinationKey(_ key: SQLAssociationKey) -> Self {
      var result = self
      result.destination.key = key
      return result
    }

    func through(_ other: _SQLAssociation) -> Self {
      _SQLAssociation(steps: other.steps + steps)
    }

    /// The destination relation, joined back to the pivot through intermediate steps, for
    /// requests that start from the destination (`record.request(for:)`, prefetching).
    func destinationRelation() -> SQLRelation {
      if steps.count == 1 { return destination.relation }
      let reversed = zip(steps, steps.dropFirst())
        .map { step, next in
          var key = step.key
          key.baseName = "grdb_" + key.baseName
          return SQLAssociationStep(
            key: key,
            condition: next.condition.reversed(to: step.relation.source.tableName),
            relation: step.relation.selectOnly([]).removingPrefetchedAssociations(),
            cardinality: .toOne
          )
        }
        .reversed()
      return destination.relation.appendingChild(
        for: _SQLAssociation(steps: Array(reversed)),
        kind: .oneRequired
      )
    }
  }

  extension SQLRelation {
    /// Joins an association, through its intermediate steps.
    func appendingChild(for association: _SQLAssociation, kind: Child.Kind) -> SQLRelation {
      let singular: Bool
      switch kind {
      case .oneOptional, .oneRequired: singular = true
      case .all: singular = false
      case .bridge: singular = association.destination.cardinality.isSingular
      }
      let key = association.destination.key.name(singular: singular)
      let child = Child(
        kind: kind,
        condition: association.destination.condition,
        relation: association.destination.relation
      )
      let initialSteps = association.steps.dropLast()
      if initialSteps.isEmpty {
        return appendingChild(child, forKey: key)
      }
      var reduced = _SQLAssociation(steps: Array(initialSteps))
      reduced.destination.relation = reduced.destination.relation
        .select([])
        .appendingChild(child, forKey: key)
      return appendingChild(for: reduced, kind: kind == .all ? .bridge : kind)
    }

    func removingPrefetchedAssociations() -> SQLRelation {
      with {
        $0.children = $0.children.compactMap { key, child in
          switch child.kind {
          case .all, .bridge:
            return nil
          case .oneOptional, .oneRequired:
            var child = child
            child.relation = child.relation.removingPrefetchedAssociations()
            return (key, child)
          }
        }
      }
    }

    var hasPrefetchedAssociations: Bool {
      children.contains { _, child in
        child.kind == .all || child.kind == .bridge || child.relation.hasPrefetchedAssociations
      }
    }

    func including(all association: _SQLAssociation) -> SQLRelation {
      appendingChild(for: association, kind: .all)
    }

    func including(optional association: _SQLAssociation) -> SQLRelation {
      appendingChild(for: association, kind: .oneOptional)
    }

    func including(required association: _SQLAssociation) -> SQLRelation {
      appendingChild(for: association, kind: .oneRequired)
    }

    func joining(optional association: _SQLAssociation) -> SQLRelation {
      var association = association
      association.destination.relation = association.destination.relation.select([])
      return appendingChild(for: association, kind: .oneOptional)
    }

    func joining(required association: _SQLAssociation) -> SQLRelation {
      var association = association
      association.destination.relation = association.destination.relation.select([])
      return appendingChild(for: association, kind: .oneRequired)
    }
  }

  // MARK: - Association protocols

  /// A relationship between two tables.
  public protocol Association: DerivableRequest, Sendable {
    associatedtype OriginRowDecoder

    var _sqlAssociation: _SQLAssociation { get set }

    /// Changes the key under which associated rows are decoded.
    func forKey(_ key: String) -> Self
  }

  extension Association {
    fileprivate func withDestinationRelation(_ update: (inout SQLRelation) throws -> Void) rethrows
      -> Self
    {
      var result = self
      try update(&result._sqlAssociation.destination.relation)
      return result
    }

    public func _including(all association: _SQLAssociation) -> Self {
      withDestinationRelation { $0 = $0.including(all: association) }
    }

    public func _including(optional association: _SQLAssociation) -> Self {
      withDestinationRelation { $0 = $0.including(optional: association) }
    }

    public func _including(required association: _SQLAssociation) -> Self {
      withDestinationRelation { $0 = $0.including(required: association) }
    }

    public func _joining(optional association: _SQLAssociation) -> Self {
      withDestinationRelation { $0 = $0.joining(optional: association) }
    }

    public func _joining(required association: _SQLAssociation) -> Self {
      withDestinationRelation { $0 = $0.joining(required: association) }
    }

    public func forKey(_ codingKey: some CodingKey) -> Self {
      forKey(codingKey.stringValue)
    }

    public func _aliased(_ alias: TableAliasBase) -> Self {
      withDestinationRelation { $0 = $0.aliased(alias) }
    }

    public func selectWhenConnected(
      _ selection: @escaping @Sendable (Database) throws -> [any SQLSelectable]
    ) -> Self {
      withDestinationRelation {
        $0 = $0.selectWhenConnected { try selection($0).map(\.sqlSelection) }
      }
    }

    public func annotatedWhenConnected(
      with selection: @escaping @Sendable (Database) throws -> [any SQLSelectable]
    ) -> Self {
      withDestinationRelation {
        $0 = $0.annotatedWhenConnected { try selection($0).map(\.sqlSelection) }
      }
    }

    public func filterWhenConnected(
      _ predicate: @escaping @Sendable (Database) throws -> any SQLExpressible
    ) -> Self {
      withDestinationRelation { $0 = $0.filterWhenConnected { try predicate($0).sqlExpression } }
    }

    public func orderWhenConnected(
      _ orderings: @escaping @Sendable (Database) throws -> [any SQLOrderingTerm]
    ) -> Self {
      withDestinationRelation {
        $0 = $0.orderWhenConnected { try orderings($0).map(\.sqlOrdering) }
      }
    }

    public func reversed() -> Self {
      withDestinationRelation { $0 = $0.reversed() }
    }

    public func unordered() -> Self {
      withDestinationRelation { $0 = $0.unordered() }
    }

    public func withStableOrder() -> Self {
      let table = databaseTableName
      return withDestinationRelation { relation in
        let stable = SQLRelation.Ordering(
          Deferred { db in
            try db.primaryKey(table).columns.map { SQLExpression.column($0).sqlOrdering }
          }
        )
        relation.ordering = relation.ordering.appending(stable)
      }
    }

    public var databaseTableName: String {
      _sqlAssociation.destination.relation.source.tableName
    }

    public func groupWhenConnected(
      _ expressions: @escaping @Sendable (Database) throws -> [any SQLExpressible]
    ) -> Self {
      withDestinationRelation {
        $0 = $0.groupWhenConnected { try expressions($0).map(\.sqlExpression) }
      }
    }

    public func havingWhenConnected(
      _ predicate: @escaping @Sendable (Database) throws -> any SQLExpressible
    ) -> Self {
      withDestinationRelation { $0 = $0.havingWhenConnected { try predicate($0).sqlExpression } }
    }

    public func distinct() -> Self {
      withDestinationRelation { $0.isDistinct = true }
    }

    public func with<T>(_ cte: CommonTableExpression<T>) -> Self {
      withDestinationRelation { $0 = $0.appendingCTE(cte.tableName, cte.cte) }
    }
  }

  /// An association that defines at most one associated record.
  public protocol AssociationToOne: Association {}

  extension AssociationToOne {
    public func forKey(_ key: String) -> Self {
      var result = self
      result._sqlAssociation = result._sqlAssociation.forDestinationKey(.fixedSingular(key))
      return result
    }
  }

  /// An association that defines several associated records.
  public protocol AssociationToMany: Association {}

  extension AssociationToMany {
    public func forKey(_ key: String) -> Self {
      var result = self
      result._sqlAssociation = result._sqlAssociation.forDestinationKey(.fixedPlural(key))
      return result
    }
  }

  private func foreignKeyAssociation(
    to relation: SQLRelation,
    key: String?,
    using foreignKey: ForeignKey?,
    originIsLeft: Bool,
    cardinality: SQLAssociationCardinality
  ) -> _SQLAssociation {
    let table = relation.source.tableName
    let associationKey: SQLAssociationKey
    if let key {
      associationKey = cardinality == .toOne ? .fixedSingular(key) : .fixedPlural(key)
    } else {
      associationKey = .inflected(table)
    }
    return _SQLAssociation(
      key: associationKey,
      condition: .foreignKey(
        SQLForeignKeyCondition(
          destinationTable: table,
          foreignKey: foreignKey,
          originIsLeft: originIsLeft
        )
      ),
      relation: relation,
      cardinality: cardinality
    )
  }

  /// The association from a record to the record its foreign key points to.
  public struct BelongsToAssociation<Origin, Destination>: AssociationToOne {
    public typealias OriginRowDecoder = Origin
    public typealias RowDecoder = Destination
    public var _sqlAssociation: _SQLAssociation

    init(to relation: SQLRelation, key: String?, using foreignKey: ForeignKey?) {
      _sqlAssociation = foreignKeyAssociation(
        to: relation,
        key: key,
        using: foreignKey,
        originIsLeft: true,
        cardinality: .toOne
      )
    }
  }

  /// The association from a record to the single record whose foreign key points to it.
  public struct HasOneAssociation<Origin, Destination>: AssociationToOne {
    public typealias OriginRowDecoder = Origin
    public typealias RowDecoder = Destination
    public var _sqlAssociation: _SQLAssociation

    init(to relation: SQLRelation, key: String?, using foreignKey: ForeignKey?) {
      _sqlAssociation = foreignKeyAssociation(
        to: relation,
        key: key,
        using: foreignKey,
        originIsLeft: false,
        cardinality: .toOne
      )
    }
  }

  /// The association from a record to the records whose foreign key points to it.
  public struct HasManyAssociation<Origin, Destination>: AssociationToMany {
    public typealias OriginRowDecoder = Origin
    public typealias RowDecoder = Destination
    public var _sqlAssociation: _SQLAssociation

    init(to relation: SQLRelation, key: String?, using foreignKey: ForeignKey?) {
      _sqlAssociation = foreignKeyAssociation(
        to: relation,
        key: key,
        using: foreignKey,
        originIsLeft: false,
        cardinality: .toMany
      )
    }
  }

  /// A to-many association through a pivot association.
  public struct HasManyThroughAssociation<Origin, Destination>: AssociationToMany {
    public typealias OriginRowDecoder = Origin
    public typealias RowDecoder = Destination
    public var _sqlAssociation: _SQLAssociation

    init<Pivot: Association, Target: Association>(through pivot: Pivot, using target: Target)
    where
      Pivot.OriginRowDecoder == Origin, Pivot.RowDecoder == Target.OriginRowDecoder,
      Target.RowDecoder == Destination
    {
      _sqlAssociation = target._sqlAssociation.through(pivot._sqlAssociation)
    }
  }

  /// A to-one association through a pivot association.
  public struct HasOneThroughAssociation<Origin, Destination>: AssociationToOne {
    public typealias OriginRowDecoder = Origin
    public typealias RowDecoder = Destination
    public var _sqlAssociation: _SQLAssociation

    init<Pivot: AssociationToOne, Target: AssociationToOne>(
      through pivot: Pivot,
      using target: Target
    )
    where
      Pivot.OriginRowDecoder == Origin, Pivot.RowDecoder == Target.OriginRowDecoder,
      Target.RowDecoder == Destination
    {
      _sqlAssociation = target._sqlAssociation.through(pivot._sqlAssociation)
    }
  }

  /// An association defined by an explicit join condition, such as an association to a
  /// common table expression.
  public struct JoinAssociation<Origin, Destination>: AssociationToOne {
    public typealias OriginRowDecoder = Origin
    public typealias RowDecoder = Destination
    public var _sqlAssociation: _SQLAssociation

    init(to relation: SQLRelation, condition: SQLAssociationCondition) {
      _sqlAssociation = _SQLAssociation(
        key: .inflected(relation.source.tableName),
        condition: condition,
        relation: relation,
        cardinality: .toOne
      )
    }
  }

  // MARK: - Joinable requests

  /// A request that can join and include associations.
  public protocol JoinableRequest<RowDecoder>: TypedRequest {
    func _including(all association: _SQLAssociation) -> Self
    func _including(optional association: _SQLAssociation) -> Self
    func _including(required association: _SQLAssociation) -> Self
    func _joining(optional association: _SQLAssociation) -> Self
    func _joining(required association: _SQLAssociation) -> Self
  }

  extension JoinableRequest {
    /// Prefetches all associated records.
    public func including<A: AssociationToMany>(all association: A) -> Self
    where A.OriginRowDecoder == RowDecoder {
      _including(all: association._sqlAssociation)
    }

    /// Includes the associated record, if it exists (LEFT JOIN).
    public func including<A: Association>(optional association: A) -> Self
    where A.OriginRowDecoder == RowDecoder {
      _including(optional: association._sqlAssociation)
    }

    /// Includes the associated record, and filters out records without one (JOIN).
    public func including<A: Association>(required association: A) -> Self
    where A.OriginRowDecoder == RowDecoder {
      _including(required: association._sqlAssociation)
    }

    /// Joins the association without selecting its columns (LEFT JOIN).
    public func joining<A: Association>(optional association: A) -> Self
    where A.OriginRowDecoder == RowDecoder {
      _joining(optional: association._sqlAssociation)
    }

    /// Joins the association without selecting its columns (JOIN).
    public func joining<A: Association>(required association: A) -> Self
    where A.OriginRowDecoder == RowDecoder {
      _joining(required: association._sqlAssociation)
    }
  }

  extension JoinableRequest where Self: SelectionRequest {
    /// Appends the columns of the associated record, if any, to the selection.
    public func annotated<A: Association>(withOptional association: A) -> Self
    where A.OriginRowDecoder == RowDecoder {
      let alias = TableAliasBase()
      let selection = association._sqlAssociation.destination.relation.selection
      return
        joining(optional: association._aliased(alias))
        .annotatedWhenConnected { db in try selection.resolve(db).map { $0.qualified(with: alias) }
        }
    }

    /// Appends the columns of the associated record to the selection, and filters out records
    /// without one.
    public func annotated<A: Association>(withRequired association: A) -> Self
    where A.OriginRowDecoder == RowDecoder {
      let alias = TableAliasBase()
      let selection = association._sqlAssociation.destination.relation.selection
      return
        joining(required: association._aliased(alias))
        .annotatedWhenConnected { db in try selection.resolve(db).map { $0.qualified(with: alias) }
        }
    }
  }

  extension QueryInterfaceRequest: JoinableRequest {
    public func _including(all association: _SQLAssociation) -> Self {
      with { $0.relation = $0.relation.including(all: association) }
    }

    public func _including(optional association: _SQLAssociation) -> Self {
      with { $0.relation = $0.relation.including(optional: association) }
    }

    public func _including(required association: _SQLAssociation) -> Self {
      with { $0.relation = $0.relation.including(required: association) }
    }

    public func _joining(optional association: _SQLAssociation) -> Self {
      with { $0.relation = $0.relation.joining(optional: association) }
    }

    public func _joining(required association: _SQLAssociation) -> Self {
      with { $0.relation = $0.relation.joining(required: association) }
    }
  }

  // MARK: - Defining associations

  extension TableRecord {
    public static func belongsTo<Destination: TableRecord>(
      _ destination: Destination.Type,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> BelongsToAssociation<Self, Destination> {
      BelongsToAssociation(to: Destination.relationForAll, key: key, using: foreignKey)
    }

    public static func hasMany<Destination: TableRecord>(
      _ destination: Destination.Type,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> HasManyAssociation<Self, Destination> {
      HasManyAssociation(to: Destination.relationForAll, key: key, using: foreignKey)
    }

    public static func hasOne<Destination: TableRecord>(
      _ destination: Destination.Type,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> HasOneAssociation<Self, Destination> {
      HasOneAssociation(to: Destination.relationForAll, key: key, using: foreignKey)
    }

    public static func belongsTo<Destination>(
      _ destination: Table<Destination>,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> BelongsToAssociation<Self, Destination> {
      BelongsToAssociation(to: destination.relationForAll, key: key, using: foreignKey)
    }

    public static func hasMany<Destination>(
      _ destination: Table<Destination>,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> HasManyAssociation<Self, Destination> {
      HasManyAssociation(to: destination.relationForAll, key: key, using: foreignKey)
    }

    public static func hasOne<Destination>(
      _ destination: Table<Destination>,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> HasOneAssociation<Self, Destination> {
      HasOneAssociation(to: destination.relationForAll, key: key, using: foreignKey)
    }

    public static func hasMany<Pivot: Association, Target: Association>(
      _ destination: Target.RowDecoder.Type,
      through pivot: Pivot,
      using target: Target,
      key: String? = nil
    ) -> HasManyThroughAssociation<Self, Target.RowDecoder>
    where Pivot.OriginRowDecoder == Self, Pivot.RowDecoder == Target.OriginRowDecoder {
      let association = HasManyThroughAssociation(through: pivot, using: target)
      return key.map { association.forKey($0) } ?? association
    }

    public static func hasOne<Pivot: AssociationToOne, Target: AssociationToOne>(
      _ destination: Target.RowDecoder.Type,
      through pivot: Pivot,
      using target: Target,
      key: String? = nil
    ) -> HasOneThroughAssociation<Self, Target.RowDecoder>
    where Pivot.OriginRowDecoder == Self, Pivot.RowDecoder == Target.OriginRowDecoder {
      let association = HasOneThroughAssociation(through: pivot, using: target)
      return key.map { association.forKey($0) } ?? association
    }

    public static func association<Destination>(
      to cte: CommonTableExpression<Destination>,
      on condition:
        @escaping @Sendable (_ left: TableAlias<Self>, _ right: TableAlias<Destination>) ->
        any SQLExpressible
    ) -> JoinAssociation<Self, Destination> {
      JoinAssociation(
        to: cte.relationForAll,
        condition: .expression { left, right in
          condition(TableAlias(root: left), TableAlias(root: right)).sqlExpression
        }
      )
    }

    public static func association<Destination>(to cte: CommonTableExpression<Destination>)
      -> JoinAssociation<Self, Destination>
    {
      JoinAssociation(to: cte.relationForAll, condition: .none)
    }

    public static func including<A: AssociationToMany>(all association: A)
      -> QueryInterfaceRequest<Self>
    where A.OriginRowDecoder == Self {
      all().including(all: association)
    }

    public static func including<A: Association>(optional association: A)
      -> QueryInterfaceRequest<Self>
    where A.OriginRowDecoder == Self {
      all().including(optional: association)
    }

    public static func including<A: Association>(required association: A)
      -> QueryInterfaceRequest<Self>
    where A.OriginRowDecoder == Self {
      all().including(required: association)
    }

    public static func joining<A: Association>(optional association: A)
      -> QueryInterfaceRequest<Self>
    where A.OriginRowDecoder == Self {
      all().joining(optional: association)
    }

    public static func joining<A: Association>(required association: A)
      -> QueryInterfaceRequest<Self>
    where A.OriginRowDecoder == Self {
      all().joining(required: association)
    }

    public static func annotated<A: Association>(withOptional association: A)
      -> QueryInterfaceRequest<Self>
    where A.OriginRowDecoder == Self {
      all().annotated(withOptional: association)
    }

    public static func annotated<A: Association>(withRequired association: A)
      -> QueryInterfaceRequest<Self>
    where A.OriginRowDecoder == Self {
      all().annotated(withRequired: association)
    }
  }

  extension TableRecord where Self: EncodableRecord {
    /// A request for the records associated with this record.
    public func request<A: Association>(for association: A) -> QueryInterfaceRequest<A.RowDecoder>
    where A.OriginRowDecoder == Self {
      guard case .foreignKey(let foreignKey) = association._sqlAssociation.pivot.condition else {
        preconditionFailure("Not implemented: request association without any foreign key")
      }
      let container = Result { try PersistenceContainer(self) }
      let table = Self.databaseTableName
      var sqlAssociation = association._sqlAssociation
      sqlAssociation.pivot.relation = sqlAssociation.pivot.relation.filterWhenConnected { db in
        try foreignKey.joinMapping(db, from: table)
          .joinExpression(leftValues: [
            container.get().databaseValues
          ])
      }
      return QueryInterfaceRequest(relation: sqlAssociation.destinationRelation())
    }
  }

  extension PersistenceContainer {
    /// Values by lowercased column name.
    var databaseValues: [String: DatabaseValue] {
      Dictionary(fields.map { ($0.0.lowercased(), $0.1) }, uniquingKeysWith: { first, _ in first })
    }
  }

  extension JoinMapping {
    /// Filters right rows that match left rows, given their values keyed by lowercased column.
    func joinExpression(leftValues rows: [[String: DatabaseValue]]) -> SQLExpression {
      guard let first = pairs.first else { return true.sqlExpression }
      if pairs.count == 1 {
        var values = Set(rows.map { $0[first.left.lowercased()] ?? .null })
        values.remove(.null)
        return values.sorted(by: databaseValueOrder).map(\.sqlExpression)
          .contains(Column(first.right))
      }
      return
        rows.compactMap { row -> SQLExpression? in
          var conditions: [SQLExpression] = []
          for pair in pairs {
            let value = row[pair.left.lowercased()] ?? .null
            if value.isNull { return nil }
            conditions.append(Column(pair.right) == value)
          }
          return conditions.joined(operator: .and)
        }
        .joined(operator: .or)
    }
  }

  /// A total order on database values: NULL, numbers, text, blobs.
  func databaseValueOrder(_ lhs: DatabaseValue, _ rhs: DatabaseValue) -> Bool {
    func rank(_ value: DatabaseValue) -> Int {
      switch value.storage {
      case .null: return 0
      case .int64, .double: return 1
      case .string: return 2
      case .blob: return 3
      }
    }
    switch (lhs.storage, rhs.storage) {
    case (.int64(let a), .int64(let b)): return a < b
    case (.int64(let a), .double(let b)): return Double(a) < b
    case (.double(let a), .int64(let b)): return a < Double(b)
    case (.double(let a), .double(let b)): return a < b
    case (.string(let a), .string(let b)): return a < b
    case (.blob(let a), .blob(let b)): return a.lexicographicallyPrecedes(b)
    default: return rank(lhs) < rank(rhs)
    }
  }

  extension Table {
    public func belongsTo<Destination: TableRecord>(
      _ destination: Destination.Type,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> BelongsToAssociation<RowDecoder, Destination> {
      BelongsToAssociation(to: Destination.relationForAll, key: key, using: foreignKey)
    }

    public func hasMany<Destination: TableRecord>(
      _ destination: Destination.Type,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> HasManyAssociation<RowDecoder, Destination> {
      HasManyAssociation(to: Destination.relationForAll, key: key, using: foreignKey)
    }

    public func hasOne<Destination: TableRecord>(
      _ destination: Destination.Type,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> HasOneAssociation<RowDecoder, Destination> {
      HasOneAssociation(to: Destination.relationForAll, key: key, using: foreignKey)
    }

    public func belongsTo<Destination>(
      _ destination: Table<Destination>,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> BelongsToAssociation<RowDecoder, Destination> {
      BelongsToAssociation(to: destination.relationForAll, key: key, using: foreignKey)
    }

    public func hasMany<Destination>(
      _ destination: Table<Destination>,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> HasManyAssociation<RowDecoder, Destination> {
      HasManyAssociation(to: destination.relationForAll, key: key, using: foreignKey)
    }

    public func hasOne<Destination>(
      _ destination: Table<Destination>,
      key: String? = nil,
      using foreignKey: ForeignKey? = nil
    ) -> HasOneAssociation<RowDecoder, Destination> {
      HasOneAssociation(to: destination.relationForAll, key: key, using: foreignKey)
    }

    public func hasMany<Pivot: Association, Target: Association>(
      _ destination: Target.RowDecoder.Type,
      through pivot: Pivot,
      using target: Target,
      key: String? = nil
    ) -> HasManyThroughAssociation<RowDecoder, Target.RowDecoder>
    where Pivot.OriginRowDecoder == RowDecoder, Pivot.RowDecoder == Target.OriginRowDecoder {
      let association = HasManyThroughAssociation(through: pivot, using: target)
      return key.map { association.forKey($0) } ?? association
    }

    public func hasOne<Pivot: AssociationToOne, Target: AssociationToOne>(
      _ destination: Target.RowDecoder.Type,
      through pivot: Pivot,
      using target: Target,
      key: String? = nil
    ) -> HasOneThroughAssociation<RowDecoder, Target.RowDecoder>
    where Pivot.OriginRowDecoder == RowDecoder, Pivot.RowDecoder == Target.OriginRowDecoder {
      let association = HasOneThroughAssociation(through: pivot, using: target)
      return key.map { association.forKey($0) } ?? association
    }

    public func association<Destination>(
      to cte: CommonTableExpression<Destination>,
      on condition:
        @escaping @Sendable (_ left: TableAlias<RowDecoder>, _ right: TableAlias<Destination>) ->
        any SQLExpressible
    ) -> JoinAssociation<RowDecoder, Destination> {
      JoinAssociation(
        to: cte.relationForAll,
        condition: .expression { left, right in
          condition(TableAlias(root: left), TableAlias(root: right)).sqlExpression
        }
      )
    }

    public func association<Destination>(to cte: CommonTableExpression<Destination>)
      -> JoinAssociation<RowDecoder, Destination>
    {
      JoinAssociation(to: cte.relationForAll, condition: .none)
    }

    public func including<A: AssociationToMany>(all association: A)
      -> QueryInterfaceRequest<RowDecoder>
    where A.OriginRowDecoder == RowDecoder {
      all().including(all: association)
    }

    public func including<A: Association>(optional association: A)
      -> QueryInterfaceRequest<RowDecoder>
    where A.OriginRowDecoder == RowDecoder {
      all().including(optional: association)
    }

    public func including<A: Association>(required association: A)
      -> QueryInterfaceRequest<RowDecoder>
    where A.OriginRowDecoder == RowDecoder {
      all().including(required: association)
    }

    public func joining<A: Association>(optional association: A)
      -> QueryInterfaceRequest<RowDecoder>
    where A.OriginRowDecoder == RowDecoder {
      all().joining(optional: association)
    }

    public func joining<A: Association>(required association: A)
      -> QueryInterfaceRequest<RowDecoder>
    where A.OriginRowDecoder == RowDecoder {
      all().joining(required: association)
    }

    public func annotated<A: Association>(withOptional association: A)
      -> QueryInterfaceRequest<RowDecoder>
    where A.OriginRowDecoder == RowDecoder {
      all().annotated(withOptional: association)
    }

    public func annotated<A: Association>(withRequired association: A)
      -> QueryInterfaceRequest<RowDecoder>
    where A.OriginRowDecoder == RowDecoder {
      all().annotated(withRequired: association)
    }
  }

  extension CommonTableExpression {
    public func association<Destination>(
      to cte: CommonTableExpression<Destination>,
      on condition:
        @escaping @Sendable (_ left: TableAlias<RowDecoder>, _ right: TableAlias<Destination>) ->
        any SQLExpressible
    ) -> JoinAssociation<RowDecoder, Destination> {
      JoinAssociation(
        to: cte.relationForAll,
        condition: .expression { left, right in
          condition(TableAlias(root: left), TableAlias(root: right)).sqlExpression
        }
      )
    }

    public func association<Destination>(to cte: CommonTableExpression<Destination>)
      -> JoinAssociation<RowDecoder, Destination>
    {
      JoinAssociation(to: cte.relationForAll, condition: .none)
    }

    public func association<Destination: TableRecord>(
      to destination: Destination.Type,
      on condition:
        @escaping @Sendable (_ left: TableAlias<RowDecoder>, _ right: TableAlias<Destination>) ->
        any SQLExpressible
    ) -> JoinAssociation<RowDecoder, Destination> {
      JoinAssociation(
        to: Destination.relationForAll,
        condition: .expression { left, right in
          condition(TableAlias(root: left), TableAlias(root: right)).sqlExpression
        }
      )
    }

    public func association<Destination: TableRecord>(to destination: Destination.Type)
      -> JoinAssociation<RowDecoder, Destination>
    {
      JoinAssociation(to: Destination.relationForAll, condition: .none)
    }

    public func association<Destination>(
      to destination: Table<Destination>,
      on condition:
        @escaping @Sendable (_ left: TableAlias<RowDecoder>, _ right: TableAlias<Destination>) ->
        any SQLExpressible
    ) -> JoinAssociation<RowDecoder, Destination> {
      JoinAssociation(
        to: destination.relationForAll,
        condition: .expression { left, right in
          condition(TableAlias(root: left), TableAlias(root: right)).sqlExpression
        }
      )
    }

    public func association<Destination>(to destination: Table<Destination>)
      -> JoinAssociation<RowDecoder, Destination>
    {
      JoinAssociation(to: destination.relationForAll, condition: .none)
    }
  }
#endif
