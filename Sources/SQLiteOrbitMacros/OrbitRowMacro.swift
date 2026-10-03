import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Synthesizes an owned value's initialization from named database result columns.
public struct OrbitRowMacro: ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard let declaration = declaration.as(StructDeclSyntax.self) else {
      throw rowDiagnostic(at: node, "'@OrbitRow' can only be applied to structs")
    }
    let options = try persistenceOptions(node)
    let rowType = context.makeUniqueName("Row")

    let reserved = [
      "orbitTableName", "orbitPrimaryKeyColumns", "orbitColumnName", "encodeOrbitDatabaseRow"
    ]
    var properties: [(name: TokenSyntax, type: TypeSyntax, column: String)] = []
    for member in declaration.memberBlock.members {
      if let initializer = member.decl.as(InitializerDeclSyntax.self),
        initializer.signature.parameterClause.parameters.count == 1,
        initializer.signature.parameterClause.parameters.first?.firstName.text == "orbitDatabaseRow"
      {
        throw rowDiagnostic(
          at: initializer,
          "'@OrbitRow' would duplicate this row initializer; use a handwritten conformance instead"
        )
      }
      if options != nil, let function = member.decl.as(FunctionDeclSyntax.self),
        reserved.contains(function.name.text.trimmingBackticks)
      {
        throw rowDiagnostic(at: function, "'@OrbitRow' would duplicate this persistence member")
      }
      if member.decl.is(IfConfigDeclSyntax.self) {
        throw rowDiagnostic(
          at: member.decl,
          "'@OrbitRow' does not support conditional members; use a handwritten conformance"
        )
      }
      guard let property = member.decl.as(VariableDeclSyntax.self) else { continue }
      if options != nil,
        property.bindings.contains(where: {
          $0.pattern.as(IdentifierPatternSyntax.self)
            .map { reserved.contains($0.identifier.text.trimmingBackticks) } ?? false
        })
      {
        throw rowDiagnostic(at: property, "'@OrbitRow' would duplicate this persistence member")
      }
      guard isStoredInstanceProperty(property) else { continue }
      guard property.bindings.count == 1,
        let binding = property.bindings.first,
        let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier
      else {
        throw rowDiagnostic(at: property, "'@OrbitRow' requires one named property per declaration")
      }
      guard !property.modifiers.contains(where: { $0.name.text == "lazy" }) else {
        throw rowDiagnostic(
          at: property,
          "'@OrbitRow' does not support lazy properties; use a handwritten conformance"
        )
      }
      guard let propertyType = binding.typeAnnotation?.type else {
        throw rowDiagnostic(
          at: identifier,
          "'@OrbitRow' requires an explicit type for stored property '\(identifier.text)'"
        )
      }
      if property.bindingSpecifier.tokenKind == .keyword(.let),
        let initializer = binding.initializer
      {
        throw rowDiagnostic(
          at: initializer,
          "'@OrbitRow' cannot decode a 'let' property with an initializer; remove the initializer or use a handwritten conformance"
        )
      }
      var columnName = identifier.text.trimmingBackticks
      var didRename = false
      for element in property.attributes {
        guard let attribute = element.as(AttributeSyntax.self) else {
          throw rowDiagnostic(
            at: element,
            "'@OrbitRow' does not support conditional property attributes"
          )
        }
        guard macroName(attribute) == "OrbitColumn" else {
          throw rowDiagnostic(
            at: attribute,
            "'@OrbitRow' does not support property wrappers or other property attributes; use a handwritten conformance"
          )
        }
        guard !didRename else {
          throw rowDiagnostic(
            at: attribute,
            "a property can have only one '@OrbitColumn' attribute"
          )
        }
        guard case .argumentList(let arguments) = attribute.arguments,
          arguments.count == 1, let argument = arguments.first, argument.label == nil,
          let name = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        else {
          throw rowDiagnostic(
            at: attribute,
            "'@OrbitColumn' requires one string literal column name"
          )
        }
        columnName = name
        didRename = true
      }
      if options != nil,
        properties.contains(where: { $0.column.utf8.elementsEqual(columnName.utf8) })
      {
        throw rowDiagnostic(
          at: property,
          "persistent properties must use distinct SQL column names"
        )
      }
      properties.append((identifier, propertyType, columnName))
    }
    let access =
      declaration.modifiers
      .first(where: {
        $0.name.text == "public" || $0.name.text == "package"
      })
      .map { "\($0.name.text) " } ?? ""
    var persistence = ""
    if let options {
      let inferredKey = properties.first { $0.name.text.trimmingBackticks == "id" }?.column
      let keys = options.primaryKey ?? inferredKey.map { [$0] } ?? []
      for (index, key) in keys.enumerated() {
        guard properties.contains(where: { $0.column.utf8.elementsEqual(key.utf8) }),
          !keys[..<index].contains(where: { $0.utf8.elementsEqual(key.utf8) })
        else {
          throw rowDiagnostic(
            at: node,
            "'primaryKey' must contain distinct stored SQL column names"
          )
        }
      }
      let mappings = properties.map {
        "case \\Self.\($0.name.trimmedDescription): return \(StringLiteralExprSyntax(content: $0.column))"
      }
      let encodings = properties.map {
        "try values.set(\\.\($0.name.trimmedDescription), to: self.\($0.name.trimmedDescription))"
      }
      let tableLiteral = StringLiteralExprSyntax(content: options.table).description
      let keyLiterals = keys.map { StringLiteralExprSyntax(content: $0).description }
        .joined(separator: ", ")
      persistence = """

        \(access)static var orbitTableName: String { \(tableLiteral) }
        \(access)static var orbitPrimaryKeyColumns: [String] { [\(keyLiterals)] }

        \(access)static func orbitColumnName(for keyPath: PartialKeyPath<Self>) -> String? {
          switch keyPath {
          \(mappings.joined(separator: "\n"))
          default: return nil
          }
        }

        \(access)func encodeOrbitDatabaseRow(into values: inout SQLiteOrbit.OrbitDatabaseRowValues<Self>) throws {
          \(encodings.joined(separator: "\n"))
        }
        """
    }
    let conformances =
      protocols.map { protocolType in
        protocolType.as(IdentifierTypeSyntax.self).map { "SQLiteOrbit.\($0.name.text)" }
          ?? protocolType.trimmedDescription
      }
      .joined(separator: ", ")
    let conformance = protocols.isEmpty ? "" : ": \(conformances)"
    let assignments = properties.map {
      "self.\($0.name.trimmedDescription) = try row[column: \(StringLiteralExprSyntax(content: $0.column)), as: \($0.type.trimmedDescription).self]"
    }
    let result: DeclSyntax = """
      extension \(type.trimmed)\(raw: conformance) {
        \(raw: access)init<\(rowType): SQLiteOrbit.OrbitDatabaseRow & ~Copyable & ~Escapable>(
          orbitDatabaseRow row: borrowing \(rowType)
        ) throws {
          \(raw: assignments.joined(separator: "\n"))
        }\(raw: persistence)
      }
      """
    return [result.cast(ExtensionDeclSyntax.self)]
  }
}

private func persistenceOptions(_ node: AttributeSyntax) throws -> (
  table: String, primaryKey: [String]?
)? {
  guard case .argumentList(let arguments) = node.arguments, !arguments.isEmpty else { return nil }
  guard arguments.count <= 2,
    let table = arguments.first, table.label?.text == "table",
    let name = table.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
  else {
    throw rowDiagnostic(at: node, "'@OrbitRow' requires a string literal table name")
  }
  guard arguments.count == 2, let primaryKey = arguments.last else { return (name, nil) }
  guard primaryKey.label?.text == "primaryKey" else {
    throw rowDiagnostic(at: node, "'@OrbitRow' accepts only 'table' and 'primaryKey' arguments")
  }
  if primaryKey.expression.is(NilLiteralExprSyntax.self) { return (name, nil) }
  guard let array = primaryKey.expression.as(ArrayExprSyntax.self) else {
    throw rowDiagnostic(
      at: node,
      "'primaryKey' must be an array of string literal SQL column names"
    )
  }
  let keys = try array.elements.map { element in
    guard let key = element.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    else {
      throw rowDiagnostic(at: element, "'primaryKey' requires string literal SQL column names")
    }
    return key
  }
  return (name, keys)
}

extension String {
  fileprivate var trimmingBackticks: String {
    if first == "`", last == "`" { return String(dropFirst().dropLast()) }
    return self
  }
}

/// Marks an explicit result-column name for the enclosing OrbitRow macro.
public struct OrbitColumnMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let enclosingType = context.lexicalContext.first {
      $0.is(StructDeclSyntax.self) || $0.is(ClassDeclSyntax.self) || $0.is(EnumDeclSyntax.self)
    }?
    .as(StructDeclSyntax.self)
    guard let property = declaration.as(VariableDeclSyntax.self),
      isStoredInstanceProperty(property),
      let enclosingType,
      enclosingType.attributes.contains(where: {
        $0.as(AttributeSyntax.self).map { macroName($0) == "OrbitRow" } ?? false
      })
    else {
      throw rowDiagnostic(
        at: node,
        "'@OrbitColumn' requires a stored instance property inside an '@OrbitRow' struct"
      )
    }
    return []
  }
}

private func isStoredInstanceProperty(_ property: VariableDeclSyntax) -> Bool {
  guard !property.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" })
  else { return false }
  for binding in property.bindings {
    if let accessorBlock = binding.accessorBlock {
      switch accessorBlock.accessors {
      case .getter: return false
      case .accessors(let accessors):
        if accessors.contains(where: {
          $0.accessorSpecifier.text != "willSet" && $0.accessorSpecifier.text != "didSet"
        }) {
          return false
        }
      }
    }
  }
  return true
}

private func macroName(_ attribute: AttributeSyntax) -> String? {
  if let type = attribute.attributeName.as(IdentifierTypeSyntax.self) { return type.name.text }
  return attribute.attributeName.as(MemberTypeSyntax.self)?.name.text
}

private func rowDiagnostic(at node: some SyntaxProtocol, _ message: String) -> DiagnosticsError {
  DiagnosticsError(diagnostics: [
    Diagnostic(node: node, message: MacroExpansionErrorMessage(message))
  ])
}
