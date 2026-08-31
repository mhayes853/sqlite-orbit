public import StructuredQueries

/// A Structured Queries statement that is safe to run in a read transaction.
public protocol DatabaseReadStatement<QueryValue>: Statement {}

/// A Structured Queries statement that requires a write transaction.
public protocol DatabaseWriteStatement<QueryValue>: Statement {}

extension Select: DatabaseReadStatement {}
extension Where: DatabaseReadStatement {}

extension Insert: DatabaseWriteStatement {}
extension Update: DatabaseWriteStatement {}
extension Delete: DatabaseWriteStatement {}

// Raw SQL is an explicit escape hatch whose access requirements cannot be checked statically.
extension SQLQueryExpression: DatabaseReadStatement, DatabaseWriteStatement {}

extension With: DatabaseReadStatement where Base: DatabaseReadStatement {}
extension With: DatabaseWriteStatement where Base: DatabaseWriteStatement {}
