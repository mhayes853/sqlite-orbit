#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// Prepares a request for an aggregate, by joining the aggregated association, and returns
  /// the aggregate expression.
  private protocol AggregatePreparation<RowDecoder> {
    associatedtype RowDecoder

    func prepare<Request: DerivableRequest>(_ request: inout Request) -> SQLExpression
    where Request.RowDecoder == RowDecoder
  }

  private struct BasePreparation<A: AssociationToMany>: AggregatePreparation {
    typealias RowDecoder = A.OriginRowDecoder
    let association: A
    let expression: SQLExpression

    func prepare<Request: DerivableRequest>(_ request: inout Request) -> SQLExpression
    where Request.RowDecoder == RowDecoder {
      let alias = TableAliasBase()
      request = request.joining(optional: association._aliased(alias)).groupByPrimaryKey()
      return expression.qualified(with: alias)
    }
  }

  private struct MapPreparation<RowDecoder>: AggregatePreparation {
    let base: any AggregatePreparation<RowDecoder>
    let transform: (SQLExpression) -> SQLExpression

    func prepare<Request: DerivableRequest>(_ request: inout Request) -> SQLExpression
    where Request.RowDecoder == RowDecoder {
      transform(base.prepare(&request))
    }
  }

  private struct CombinePreparation<RowDecoder>: AggregatePreparation {
    let lhs: any AggregatePreparation<RowDecoder>
    let rhs: any AggregatePreparation<RowDecoder>
    let combine: (SQLExpression, SQLExpression) -> SQLExpression

    func prepare<Request: DerivableRequest>(_ request: inout Request) -> SQLExpression
    where Request.RowDecoder == RowDecoder {
      let lhs = self.lhs.prepare(&request)
      let rhs = self.rhs.prepare(&request)
      return combine(lhs, rhs)
    }
  }

  /// An aggregate value computed from a to-many association, such as `Team.players.count`.
  public struct AssociationAggregate<RowDecoder> {
    fileprivate let preparation: any AggregatePreparation<RowDecoder>
    var key: String?

    fileprivate init(_ preparation: any AggregatePreparation<RowDecoder>, key: String? = nil) {
      self.preparation = preparation
      self.key = key
    }

    func prepare<Request: DerivableRequest>(_ request: inout Request) -> SQLExpression
    where Request.RowDecoder == RowDecoder {
      preparation.prepare(&request)
    }

    /// Names the aggregate in the selection.
    public func forKey(_ key: String) -> Self {
      var result = self
      result.key = key
      return result
    }

    /// Names the aggregate in the selection.
    public func forKey(_ key: some CodingKey) -> Self {
      forKey(key.stringValue)
    }

    fileprivate func map(_ transform: @escaping (SQLExpression) -> SQLExpression) -> Self {
      Self(MapPreparation(base: preparation, transform: transform))
    }

    fileprivate static func combine(
      _ lhs: Self,
      _ rhs: Self,
      _ combine: @escaping (SQLExpression, SQLExpression) -> SQLExpression
    ) -> Self {
      Self(CombinePreparation(lhs: lhs.preparation, rhs: rhs.preparation, combine: combine))
    }
  }

  extension AssociationToMany {
    private func aggregate(_ expression: SQLExpression) -> AssociationAggregate<OriginRowDecoder> {
      AssociationAggregate(BasePreparation(association: self, expression: expression))
    }

    private var singularKey: String {
      _sqlAssociation.destination.key.name(singular: true)
    }

    private func aggregate(
      _ function: String,
      _ expression: some SQLSpecificExpressible,
      key: (_ name: String, _ column: String) -> String
    ) -> AssociationAggregate<OriginRowDecoder> {
      let result = aggregate(.function(function, [expression.sqlExpression]))
      guard let column = expression as? any ColumnExpression else { return result }
      return result.forKey(key(singularKey, column.name.uppercasingFirstCharacter))
    }

    /// The number of associated records.
    public var count: AssociationAggregate<OriginRowDecoder> {
      aggregate(.aggregate("COUNT", [.fastPrimaryKey], distinct: true))
        .forKey("\(singularKey)Count")
    }

    /// Whether there is no associated record.
    public var isEmpty: AssociationAggregate<OriginRowDecoder> {
      aggregate(.isEmpty(.aggregate("COUNT", [.fastPrimaryKey], distinct: true)))
        .forKey("hasNo\(singularKey.uppercasingFirstCharacter)")
    }

    public func average(_ expression: some SQLSpecificExpressible)
      -> AssociationAggregate<OriginRowDecoder>
    {
      aggregate("AVG", expression) { "average\($0.uppercasingFirstCharacter)\($1)" }
    }

    public func max(_ expression: some SQLSpecificExpressible)
      -> AssociationAggregate<OriginRowDecoder>
    {
      aggregate("MAX", expression) { "max\($0.uppercasingFirstCharacter)\($1)" }
    }

    public func min(_ expression: some SQLSpecificExpressible)
      -> AssociationAggregate<OriginRowDecoder>
    {
      aggregate("MIN", expression) { "min\($0.uppercasingFirstCharacter)\($1)" }
    }

    public func sum(_ expression: some SQLSpecificExpressible)
      -> AssociationAggregate<OriginRowDecoder>
    {
      aggregate("SUM", expression) { "\($0)\($1)Sum" }
    }

    public func total(_ expression: some SQLSpecificExpressible)
      -> AssociationAggregate<OriginRowDecoder>
    {
      aggregate("TOTAL", expression) { "\($0)\($1)Sum" }
    }
  }

  extension AssociationToMany where RowDecoder: TableRecord {
    public func average(
      _ expression: (RowDecoder.DatabaseComponents) throws -> some SQLSpecificExpressible
    ) rethrows -> AssociationAggregate<OriginRowDecoder> {
      try average(expression(RowDecoder.databaseComponents))
    }

    public func max(
      _ expression: (RowDecoder.DatabaseComponents) throws -> some SQLSpecificExpressible
    ) rethrows -> AssociationAggregate<OriginRowDecoder> {
      try max(expression(RowDecoder.databaseComponents))
    }

    public func min(
      _ expression: (RowDecoder.DatabaseComponents) throws -> some SQLSpecificExpressible
    ) rethrows -> AssociationAggregate<OriginRowDecoder> {
      try min(expression(RowDecoder.databaseComponents))
    }

    public func sum(
      _ expression: (RowDecoder.DatabaseComponents) throws -> some SQLSpecificExpressible
    ) rethrows -> AssociationAggregate<OriginRowDecoder> {
      try sum(expression(RowDecoder.databaseComponents))
    }

    public func total(
      _ expression: (RowDecoder.DatabaseComponents) throws -> some SQLSpecificExpressible
    ) rethrows -> AssociationAggregate<OriginRowDecoder> {
      try total(expression(RowDecoder.databaseComponents))
    }
  }

  // MARK: - Operators

  extension AssociationAggregate {
    public static prefix func ! (aggregate: Self) -> Self { aggregate.map { !$0 } }
    public static prefix func - (aggregate: Self) -> Self { aggregate.map { -$0 } }

    public static func && (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 && $1 } }
    public static func && (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 && rhs } }
    public static func && (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs && $0 } }
    public static func || (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 || $1 } }
    public static func || (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 || rhs } }
    public static func || (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs || $0 } }

    public static func == (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 == $1 } }
    public static func == (lhs: Self, rhs: (any SQLExpressible)?) -> Self {
      lhs.map { $0 == rhs }
    }
    public static func == (lhs: (any SQLExpressible)?, rhs: Self) -> Self {
      rhs.map { lhs == $0 }
    }
    public static func == (lhs: Self, rhs: Bool) -> Self { lhs.map { $0 == rhs } }
    public static func == (lhs: Bool, rhs: Self) -> Self { rhs.map { lhs == $0 } }
    public static func != (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 != $1 } }
    public static func != (lhs: Self, rhs: (any SQLExpressible)?) -> Self {
      lhs.map { $0 != rhs }
    }
    public static func != (lhs: (any SQLExpressible)?, rhs: Self) -> Self {
      rhs.map { lhs != $0 }
    }
    public static func != (lhs: Self, rhs: Bool) -> Self { lhs.map { $0 != rhs } }
    public static func != (lhs: Bool, rhs: Self) -> Self { rhs.map { lhs != $0 } }
    public static func === (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 === $1 } }
    public static func === (lhs: Self, rhs: (any SQLExpressible)?) -> Self {
      lhs.map { $0 === rhs }
    }
    public static func === (lhs: (any SQLExpressible)?, rhs: Self) -> Self {
      rhs.map { lhs === $0 }
    }
    public static func !== (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 !== $1 } }
    public static func !== (lhs: Self, rhs: (any SQLExpressible)?) -> Self {
      lhs.map { $0 !== rhs }
    }
    public static func !== (lhs: (any SQLExpressible)?, rhs: Self) -> Self {
      rhs.map { lhs !== $0 }
    }

    public static func <= (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 <= $1 } }
    public static func <= (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 <= rhs } }
    public static func <= (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs <= $0 } }
    public static func < (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 < $1 } }
    public static func < (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 < rhs } }
    public static func < (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs < $0 } }
    public static func > (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 > $1 } }
    public static func > (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 > rhs } }
    public static func > (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs > $0 } }
    public static func >= (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 >= $1 } }
    public static func >= (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 >= rhs } }
    public static func >= (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs >= $0 } }

    public static func + (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 + $1 } }
    public static func + (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 + rhs } }
    public static func + (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs + $0 } }
    public static func - (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 - $1 } }
    public static func - (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 - rhs } }
    public static func - (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs - $0 } }
    public static func * (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 * $1 } }
    public static func * (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 * rhs } }
    public static func * (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs * $0 } }
    public static func / (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs) { $0 / $1 } }
    public static func / (lhs: Self, rhs: some SQLExpressible) -> Self { lhs.map { $0 / rhs } }
    public static func / (lhs: some SQLExpressible, rhs: Self) -> Self { rhs.map { lhs / $0 } }

    public static func ?? (lhs: Self, rhs: some SQLExpressible) -> Self {
      var result = lhs.map { $0 ?? rhs }
      result.key = lhs.key
      return result
    }
  }

  public func abs<RowDecoder>(_ aggregate: AssociationAggregate<RowDecoder>)
    -> AssociationAggregate<RowDecoder>
  {
    aggregate.map { abs($0) }
  }

  public func cast<RowDecoder>(
    _ aggregate: AssociationAggregate<RowDecoder>,
    as storageClass: Database.StorageClass
  ) -> AssociationAggregate<RowDecoder> {
    var result = aggregate.map { cast($0, as: storageClass) }
    result.key = aggregate.key
    return result
  }

  public func length<RowDecoder>(_ aggregate: AssociationAggregate<RowDecoder>)
    -> AssociationAggregate<RowDecoder>
  {
    aggregate.map { length($0) }
  }

  // MARK: - Requests

  extension DerivableRequest {
    private func annotated(with aggregate: AssociationAggregate<RowDecoder>) -> Self {
      var request = self
      let expression = aggregate.prepare(&request)
      if let key = aggregate.key {
        return request.annotated(with: [expression.forKey(key)])
      }
      return request.annotated(with: [expression])
    }

    /// Appends association aggregates to the selection.
    public func annotated(with aggregates: AssociationAggregate<RowDecoder>...) -> Self {
      annotated(with: aggregates)
    }

    /// Appends association aggregates to the selection.
    public func annotated(with aggregates: [AssociationAggregate<RowDecoder>]) -> Self {
      aggregates.reduce(self) { $0.annotated(with: $1) }
    }

    /// Filters by an association aggregate.
    public func having(_ predicate: AssociationAggregate<RowDecoder>) -> Self {
      var request = self
      let expression = predicate.prepare(&request)
      return request.having(expression)
    }
  }

  extension TableRecord {
    public static func annotated(with aggregates: AssociationAggregate<Self>...)
      -> QueryInterfaceRequest<Self>
    {
      all().annotated(with: aggregates)
    }

    public static func annotated(with aggregates: [AssociationAggregate<Self>])
      -> QueryInterfaceRequest<Self>
    {
      all().annotated(with: aggregates)
    }

    public static func having(_ predicate: AssociationAggregate<Self>) -> QueryInterfaceRequest<
      Self
    > {
      all().having(predicate)
    }
  }

  extension Table {
    public func annotated(with aggregates: AssociationAggregate<RowDecoder>...)
      -> QueryInterfaceRequest<RowDecoder>
    {
      all().annotated(with: aggregates)
    }

    public func annotated(with aggregates: [AssociationAggregate<RowDecoder>])
      -> QueryInterfaceRequest<RowDecoder>
    {
      all().annotated(with: aggregates)
    }

    public func having(_ predicate: AssociationAggregate<RowDecoder>)
      -> QueryInterfaceRequest<RowDecoder>
    {
      all().having(predicate)
    }
  }
#endif
