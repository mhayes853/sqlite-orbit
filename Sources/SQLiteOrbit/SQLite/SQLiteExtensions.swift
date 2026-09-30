/// An extension's C initializer, with an opaque pointer to `sqlite3_api_routines`.
///
/// The initializer and its code must remain loaded for as long as SQLite can call them. Error
/// messages returned through the second argument must be allocated by the receiving runtime.
public typealias SQLiteExtensionInitializer =
  @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeRawPointer?
  ) -> Int32

extension SQLiteLibrary {
  /// Extension initialization supported by a runtime.
  ///
  /// Custom runtimes supply their own automatic registration bindings. Orbit identifies Apple
  /// system SQLite separately so integrations compiled against its SDK can initialize directly
  /// without guessing from a platform, version number, or diagnostic name.
  public struct Extensions: Sendable {
    /// Process-global automatic registration, when supported.
    public var autoExtensions: AutoExtensions?

    let isAppleSystemSQLite: Bool

    /// Creates extension support for a custom SQLite runtime.
    public init(autoExtensions: AutoExtensions) {
      self.autoExtensions = autoExtensions
      self.isAppleSystemSQLite = false
    }

    private init() {
      self.autoExtensions = nil
      self.isAppleSystemSQLite = true
    }

    // Only the known system library sets this. A custom library cannot accidentally opt into
    // calling functions from Apple's SQLite on its own connection.
    static let appleSystem = Self()
  }

  /// Native bindings for automatic extension registration in one SQLite runtime.
  public struct AutoExtensions: Sendable {
    /// Registers an initializer: `sqlite3_auto_extension`.
    public var register: @Sendable (@convention(c) () -> Void) -> Int32

    /// Cancels an initializer for future connections: `sqlite3_cancel_auto_extension`.
    public var cancel: @Sendable (@convention(c) () -> Void) -> Int32

    /// Creates bindings to the selected runtime's registration entry points.
    public init(
      register: @escaping @Sendable (@convention(c) () -> Void) -> Int32,
      cancel: @escaping @Sendable (@convention(c) () -> Void) -> Int32
    ) {
      self.register = register
      self.cancel = cancel
    }
  }

  /// Registers an initializer for every future connection opened by this runtime.
  ///
  /// Existing connections are unaffected. Registration is runtime-wide, including connections
  /// outside Orbit. Registering the same initializer again is a harmless no-op.
  ///
  /// - Throws: ``SQLiteFeatureUnavailableError`` when automatic registration is unsupported, or
  ///   ``SQLiteError`` when registration fails.
  public func registerAutoExtension(_ initializer: SQLiteExtensionInitializer) throws {
    guard let automatic = extensions?.autoExtensions else {
      throw SQLiteFeatureUnavailableError(libraryName: name, feature: .autoExtensions)
    }
    // SQLite declares a void(void) pointer but calls it with the initializer's three arguments.
    let code = automatic.register(unsafeBitCast(initializer, to: (@convention(c) () -> Void).self))
    guard code == SQLiteResultCode.ok.rawValue else {
      throw SQLiteError(
        code: SQLiteResultCode(rawValue: code),
        message: "Failed to register an automatic SQLite extension."
      )
    }
  }

  /// Removes an initializer from this runtime's list for future connections.
  ///
  /// Already initialized connections retain the extension. This does not unload its code.
  /// - Returns: Whether the initializer was registered and removed.
  /// - Throws: ``SQLiteFeatureUnavailableError`` when automatic registration is unsupported.
  @discardableResult
  public func cancelAutoExtension(_ initializer: SQLiteExtensionInitializer) throws -> Bool {
    guard let automatic = extensions?.autoExtensions else {
      throw SQLiteFeatureUnavailableError(libraryName: name, feature: .autoExtensions)
    }
    return automatic.cancel(unsafeBitCast(initializer, to: (@convention(c) () -> Void).self)) != 0
  }
}
