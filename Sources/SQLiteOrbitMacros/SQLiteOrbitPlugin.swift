import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SQLiteOrbitPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [SQLiteLibraryMacro.self]
}
