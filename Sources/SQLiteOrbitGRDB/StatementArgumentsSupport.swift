#if canImport(Foundation) && canImport(Dispatch)
  import Foundation

  extension StatementArguments: CustomStringConvertible {
    /// Whether there are no positional or named arguments.
    public var isEmpty: Bool {
      values.isEmpty && namedValues.isEmpty
    }

    public var description: String {
      let named = namedValues.map { "\(String(reflecting: $0.key)): \($0.value)" }
      return "[" + (named + values.map(\.description)).joined(separator: ", ") + "]"
    }

    /// Creates positional arguments from an array, or nil unless every element is
    /// DatabaseValueConvertible.
    public init?(_ array: [Any]) {
      var values: [(any DatabaseValueConvertible)?] = []
      for element in array {
        guard let value = DatabaseValue(value: element) else {
          return nil
        }
        values.append(value)
      }
      self.init(values)
    }

    /// Creates named arguments from a dictionary, or nil unless all keys are strings and all
    /// values are DatabaseValueConvertible.
    public init?(_ dictionary: [AnyHashable: Any]) {
      var values: [String: (any DatabaseValueConvertible)?] = [:]
      for (key, element) in dictionary {
        guard let key = key as? String, let value = DatabaseValue(value: element) else {
          return nil
        }
        values[key] = value
      }
      self.init(values)
    }
  }
#endif
