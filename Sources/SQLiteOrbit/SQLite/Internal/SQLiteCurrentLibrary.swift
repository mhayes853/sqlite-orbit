#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

// A `@convention(c)` callback captures nothing, so a collation or function running inside
// `sqlite3_step` has no way to name the table its connection was opened through. The handle binds
// it to the current thread for as long as it is stepping statements, which is the only window in
// which a callback can fire.
//
// The binding is taken once per transaction rather than per step, so it costs nothing on the paths
// that matter.
enum SQLiteCurrentLibrary {
  private static let key: pthread_key_t = {
    var key = pthread_key_t()
    let code = pthread_key_create(&key, nil)
    precondition(code == 0, "Could not create the thread key a SQLite callback finds its build by.")
    return key
  }()

  static var current: UnsafePointer<SQLiteLibrary> {
    guard let value = pthread_getspecific(key) else {
      fatalError(
        """
        A SQLite callback ran on a thread that was not stepping a statement. Collations and \
        functions registered through SQLiteConfiguration are only reachable from statements this \
        package runs.
        """
      )
    }
    return UnsafeRawPointer(value).assumingMemoryBound(to: SQLiteLibrary.self)
  }

  // The previous binding is returned rather than cleared, so that a nested statement — a setup
  // running SQL of its own, say — leaves the outer one intact once this one ends.
  static func bind(_ library: UnsafePointer<SQLiteLibrary>) -> UnsafeMutableRawPointer? {
    let previous = pthread_getspecific(key)
    pthread_setspecific(key, UnsafeRawPointer(library))
    return previous
  }

  static func unbind(restoring previous: UnsafeMutableRawPointer?) {
    pthread_setspecific(key, previous)
  }
}
