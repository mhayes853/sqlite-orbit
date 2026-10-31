#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  /// English pluralization and singularization rules, used to derive association keys and
  /// foreign key names (`team` <-> `teams`).
  public struct Inflections: Sendable {
    private struct Rule: @unchecked Sendable {
      // NSRegularExpression is immutable once created.
      let expression: NSRegularExpression
      let template: String
    }

    private var pluralRules: [Rule] = []
    private var singularRules: [Rule] = []
    private var uncountableExpressions: [String: Rule] = [:]

    public init() {}

    /// Adds a pluralization rule. Rules added later take precedence.
    public mutating func plural(
      _ pattern: String,
      options: NSRegularExpression.Options = [.caseInsensitive],
      _ template: String
    ) {
      pluralRules.append(Rule(expression: Self.regex(pattern, options), template: template))
    }

    /// Adds a singularization rule. Rules added later take precedence.
    public mutating func singular(
      _ pattern: String,
      options: NSRegularExpression.Options = [.caseInsensitive],
      _ template: String
    ) {
      singularRules.append(Rule(expression: Self.regex(pattern, options), template: template))
    }

    /// Adds words that have no plural form.
    public mutating func uncountableWords(_ words: [String]) {
      for word in words {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\Z"
        uncountableExpressions[word] = Rule(
          expression: Self.regex(pattern, [.caseInsensitive]),
          template: ""
        )
      }
    }

    /// Adds an irregular singular/plural pair, applied to word suffixes.
    public mutating func irregularSuffix(_ singular: String, _ plural: String) {
      let s0 = singular.first!
      let sRest = singular.dropFirst()
      let p0 = plural.first!
      let pRest = plural.dropFirst()
      if s0.uppercased() == p0.uppercased() {
        self.plural("(\(s0))\(sRest)$", "$1\(pRest)")
        self.plural("(\(p0))\(pRest)$", "$1\(pRest)")
        self.singular("(\(s0))\(sRest)$", "$1\(sRest)")
        self.singular("(\(p0))\(pRest)$", "$1\(sRest)")
      } else {
        for (first, replacement) in [(s0, p0), (p0, p0)] {
          let rest = first == s0 ? sRest : pRest
          self.plural(
            "\(first.uppercased())(?i)\(rest)$",
            options: [],
            replacement.uppercased() + pRest
          )
          self.plural(
            "\(first.lowercased())(?i)\(rest)$",
            options: [],
            replacement.lowercased() + pRest
          )
        }
        for first in [s0, p0] {
          let rest = first == s0 ? sRest : pRest
          self.singular("\(first.uppercased())(?i)\(rest)$", options: [], s0.uppercased() + sRest)
          self.singular("\(first.lowercased())(?i)\(rest)$", options: [], s0.lowercased() + sRest)
        }
      }
    }

    public func pluralize(_ string: String) -> String {
      inflect(string, rules: pluralRules)
    }

    public func singularize(_ string: String) -> String {
      inflect(string, rules: singularRules)
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options)
      -> NSRegularExpression
    {
      try! NSRegularExpression(pattern: pattern, options: options)
    }

    private func isUncountable(_ word: String) -> Bool {
      let range = NSRange(location: 0, length: word.utf16.count)
      return uncountableExpressions.values.contains {
        $0.expression.firstMatch(in: word, options: [], range: range) != nil
      }
    }

    /// Inflects the last word of the string, preserving any trailing digits.
    private func inflect(_ string: String, rules: [Rule]) -> String {
      let start = Self.startIndexOfLastWord(string)
      let end = Self.endIndexOfDigitlessRadical(string)
      guard start <= end else { return string }
      let word = String(string[start..<end])
      if word.isEmpty || isUncountable(word) { return string }
      let range = NSRange(word.startIndex..<word.endIndex, in: word)
      var inflected = word
      for rule in rules.reversed() {
        let result = NSMutableString(string: word)
        if rule.expression.replaceMatches(
          in: result,
          options: [],
          range: range,
          withTemplate: rule.template
        ) > 0 {
          inflected = String(result)
          break
        }
      }
      return String(string[..<start]) + inflected + String(string[end...])
    }

    static func startIndexOfLastWord(_ string: String) -> String.Index {
      let range = NSRange(string.startIndex..<string.endIndex, in: string)
      func match(_ expression: NSRegularExpression, offset: Bool) -> String.Index? {
        guard let result = expression.firstMatch(in: string, options: [], range: range),
          result.range.location != NSNotFound,
          let found = Range(result.range, in: string)
        else {
          return nil
        }
        return offset ? string.index(after: found.lowerBound) : found.lowerBound
      }
      return [
        match(wordBoundary, offset: false),
        match(underscoreBoundary, offset: true),
        match(caseBoundary, offset: true)
      ]
      .compactMap { $0 }.max() ?? string.startIndex
    }

    static func endIndexOfDigitlessRadical(_ string: String) -> String.Index {
      var index = string.endIndex
      while index > string.startIndex {
        let previous = string.index(before: index)
        guard string[previous].isASCII, string[previous].isNumber else { break }
        index = previous
      }
      return index
    }

    nonisolated(unsafe) private static let wordBoundary = regex("\\b\\w+$", [])
    nonisolated(unsafe) private static let underscoreBoundary = regex("_[^_]+$", [])
    nonisolated(unsafe) private static let caseBoundary = regex("[^A-Z][A-Z]+[a-z1-9]+$", [])

    /// The default English inflections.
    nonisolated(unsafe) public static var `default`: Inflections = {
      var inflections = Inflections()
      for (pattern, template) in [
        ("$", "s"), ("s$", "s"), ("^(ax|test)is$", "$1es"), ("(octop|vir)us$", "$1i"),
        ("(octop|vir)i$", "$1i"), ("(alias|bias|canvas|focus|gas|lens|status)$", "$1es"),
        ("(bu)s$", "$1ses"), ("(buffal|tomat|her)o$", "$1oes"), ("([ti])um$", "$1a"),
        ("([ti])a$", "$1a"), ("sis$", "ses"), ("(?:([^f])fe|([lr])f)$", "$1$2ves"),
        ("(hive)$", "$1s"), ("([^aeiouy]|qu)y$", "$1ies"), ("(x|ch|ss|sh)$", "$1es"),
        ("(matr|vert|ind)(?:ix|ex)$", "$1ices"), ("^(m|l)ouse$", "$1ice"), ("^(m|l)ice$", "$1ice"),
        ("^(ox)$", "$1en"), ("^(oxen)$", "$1"), ("(quiz)$", "$1zes"), ("(canva)s$", "$1ses")
      ] {
        inflections.plural(pattern, template)
      }
      for (pattern, template) in [
        ("s$", ""), ("(ss)$", "$1"), ("(n)ews$", "$1ews"), ("([ti])a$", "$1um"),
        ("((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)(sis|ses)$", "$1sis"),
        ("(^analy)(sis|ses)$", "$1sis"), ("([^f])ves$", "$1fe"), ("(hive)s$", "$1"),
        ("(tive)s$", "$1"), ("([lr])ves$", "$1f"), ("([^aeiouy]|qu)ies$", "$1y"),
        ("(s)eries$", "$1eries"), ("(m)ovies$", "$1ovie"), ("(x|ch|ss|sh)es$", "$1"),
        ("^(m|l)ice$", "$1ouse"), ("(bus)(es)?$", "$1"), ("(o)es$", "$1"), ("(shoe)s$", "$1"),
        ("(cris|test)(is|es)$", "$1is"), ("^(a)x[ie]s$", "$1xis"), ("(octop|vir)(us|i)$", "$1us"),
        ("(alias|bias|canvas|focus|gas|lens|status)(es)?$", "$1"), ("^(ox)en$", "$1"),
        ("(vert|ind)ices$", "$1ex"), ("(matr)ices$", "$1ix"), ("(quiz)zes$", "$1"),
        ("(database)s$", "$1")
      ] {
        inflections.singular(pattern, template)
      }
      inflections.uncountableWords([
        "advice", "corps", "dice", "equipment", "fish", "information", "jeans", "kudos", "money",
        "offspring", "police", "rice", "sheep", "species"
      ])
      for (singular, plural) in [
        ("child", "children"), ("foot", "feet"), ("leaf", "leaves"), ("man", "men"),
        ("move", "moves"), ("person", "people"), ("sex", "sexes"), ("specimen", "specimens"),
        ("zombie", "zombies")
      ] {
        inflections.irregularSuffix(singular, plural)
      }
      return inflections
    }()
  }

  extension String {
    var uppercasingFirstCharacter: String {
      guard let first else { return self }
      return String(first).uppercased() + dropFirst()
    }

    var pluralized: String { Inflections.default.pluralize(self) }

    var singularized: String { Inflections.default.singularize(self) }

    var digitlessRadical: String {
      String(self[..<Inflections.endIndexOfDigitlessRadical(self)])
    }
  }
#endif
