/// The expression a ``FetchAll`` property groups its rows by.
///
/// You do not build one. Swift builds it from the `sectionBy:` closure, which is why that closure
/// can be written as a column, an ordering of one, or a branch between them:
///
/// ```swift
/// @FetchAll(Reminder.all, sectionBy: \.priority) var byPriority
/// @FetchAll(Reminder.all, sectionBy: { $0.priority.desc() }) var byDescendingPriority
/// ```
@_documentation(visibility: private)
public struct _OrbitFetchSectioning<Key>: Hashable, Sendable {
  let select: QueryFragment
  let order: QueryFragment

  init(_ expression: some QueryExpression) {
    self.select = expression.queryFragment
    self.order = expression.queryFragment
  }

  init<Value>(_ orderingTerm: _OrderingTerm<Value>) {
    self.select = orderingTerm.baseQueryFragment
    self.order = orderingTerm.queryFragment
  }
}

/// Builds the expression a ``FetchAll`` property groups its rows by.
@_documentation(visibility: private)
@resultBuilder
public enum _OrbitFetchSectionBuilder<Key> {
  public static func buildExpression(
    _ expression: some QueryExpression<Key>
  ) -> _OrbitFetchSectioning<Key> {
    _OrbitFetchSectioning(expression)
  }

  public static func buildExpression(
    _ orderingTerm: _OrderingTerm<Key>
  ) -> _OrbitFetchSectioning<Key> {
    _OrbitFetchSectioning(orderingTerm)
  }

  public static func buildBlock(
    _ component: _OrbitFetchSectioning<Key>
  ) -> _OrbitFetchSectioning<Key> {
    component
  }

  @available(
    *,
    unavailable,
    message: "Sectioning is required here. Add an 'else' branch, or section by an optional key."
  )
  public static func buildOptional(
    _ component: _OrbitFetchSectioning<Key>?
  ) -> _OrbitFetchSectioning<Key> {
    fatalError()
  }

  public static func buildEither(
    first component: _OrbitFetchSectioning<Key>
  ) -> _OrbitFetchSectioning<Key> {
    component
  }

  public static func buildEither(
    second component: _OrbitFetchSectioning<Key>
  ) -> _OrbitFetchSectioning<Key> {
    component
  }
}

extension _OrbitFetchSectionBuilder where Key: _OptionalProtocol {
  public static func buildExpression(
    _ expression: Never?
  ) -> _OrbitFetchSectioning<Key>? {
    nil
  }

  @_disfavoredOverload
  public static func buildExpression(
    _ expression: some QueryExpression<some _OptionalPromotable<Key>>
  ) -> _OrbitFetchSectioning<Key>? {
    _OrbitFetchSectioning(expression)
  }

  @_disfavoredOverload
  public static func buildExpression(
    _ orderingTerm: _OrderingTerm<some _OptionalPromotable<Key>>
  ) -> _OrbitFetchSectioning<Key>? {
    _OrbitFetchSectioning(orderingTerm)
  }

  @_disfavoredOverload
  public static func buildBlock(
    _ component: _OrbitFetchSectioning<Key>?
  ) -> _OrbitFetchSectioning<Key>? {
    component
  }

  public static func buildOptional(
    _ component: _OrbitFetchSectioning<Key>??
  ) -> _OrbitFetchSectioning<Key>? {
    component ?? nil
  }

  @_disfavoredOverload
  public static func buildEither(
    first component: _OrbitFetchSectioning<Key>?
  ) -> _OrbitFetchSectioning<Key>? {
    component
  }

  @_disfavoredOverload
  public static func buildEither(
    second component: _OrbitFetchSectioning<Key>?
  ) -> _OrbitFetchSectioning<Key>? {
    component
  }
}
