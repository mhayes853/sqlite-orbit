// The requests behind `@FetchAll` and `@FetchOne`. Each holds the statement it was built from as a
// query fragment, which is both what it runs and what gives it its identity: two properties built
// from statements that render the same SQL and bindings describe the same read.

protocol OrbitFetchStatementRequest: OrbitFetchKeyRequest {
  associatedtype QueryValue: QueryRepresentable

  var query: QueryFragment { get }

  init(query: QueryFragment)
}

extension OrbitFetchStatementRequest {
  init(statement: some Statement<QueryValue>) {
    self.init(query: statement.query)
  }

  /// The query as an expression the transaction can read the request's value from.
  var expression: SQLQueryExpression<QueryValue> {
    SQLQueryExpression(query, as: QueryValue.self)
  }
}

struct OrbitFetchAllStatementRequest<QueryValue: QueryRepresentable>: OrbitFetchStatementRequest
where QueryValue.QueryOutput: Sendable {
  let query: QueryFragment

  func fetch(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws -> OrbitFetchSectionCollection<QueryValue.QueryOutput, String?> {
    // Every `@FetchAll` reads into the sectioned shape, so that a property with no `sectionBy:`
    // expression still projects one section holding every row, and so that a property can be
    // given a sectioned query later without changing what it stores.
    OrbitFetchSectionCollection(
      elements: try transaction.fetchAll(expression),
      sectionName: nil
    )
  }
}

struct OrbitFetchOneStatementRequest<QueryValue: QueryRepresentable>: OrbitFetchStatementRequest
where QueryValue.QueryOutput: Sendable {
  let query: QueryFragment

  func fetch(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws -> QueryValue.QueryOutput {
    guard let value = try transaction.fetchOne(expression) else {
      throw OrbitDatabaseRecordNotFoundError()
    }
    return value
  }
}

struct OrbitFetchOptionalStatementRequest<QueryValue: QueryRepresentable>:
  OrbitFetchStatementRequest
where QueryValue.QueryOutput: Sendable {
  let query: QueryFragment

  func fetch(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws -> QueryValue.QueryOutput? {
    try transaction.fetchOne(expression)
  }
}

struct OrbitFetchOptionalProtocolStatementRequest<
  QueryValue: QueryRepresentable & _OptionalProtocol
>: OrbitFetchStatementRequest
where QueryValue.QueryOutput: _OptionalProtocol & Sendable {
  let query: QueryFragment

  func fetch(
    _ transaction: borrowing SQLiteReadTransaction
  ) throws -> QueryValue.QueryOutput {
    try transaction.fetchOne(expression) ?? ._none
  }
}
