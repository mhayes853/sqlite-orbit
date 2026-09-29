#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Android)
  import Android
#elseif canImport(WASILibc)
  import WASILibc
#endif

/// What the package needs to know of the file system and the process's place in it, asked of the
/// C library rather than of Foundation's `FileManager`.
///
/// Each answer is the one `FileManager` gives, so a process built without Foundation agrees with
/// one built with it on where a database is and where its coordination directory is.
enum FileSystem {
  /// The directory for temporary files, ending in a slash, as `FileManager.default`'s
  /// `temporaryDirectory` spells it.
  ///
  /// - Darwin: the per-user temporary directory, `_CS_DARWIN_USER_TEMP_DIR`, then `TMPDIR`, then
  ///   `/tmp/`.
  /// - Linux: `TMPDIR`, then `/tmp/`.
  /// - Android: `TMPDIR`, then `/data/local/tmp/`, which is where Bionic keeps temporary files.
  /// - WASI: `/tmp/`.
  ///
  /// `TMPDIR` is not read by a process running with privileges it did not start with.
  static var temporaryDirectoryPath: String {
    #if canImport(Darwin)
      // No value, or a failure, which can be for want of space to create the directory, falls
      // through to `TMPDIR`.
      let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
      if length > 0 {
        var buffer = [CChar](repeating: 0, count: length)
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
          return string(fromCString: buffer)
        }
      }
    #endif
    #if !os(WASI) && !os(Windows)
      if let value = environmentValue(securelyNamed: "TMPDIR") {
        return value.utf8.last == UInt8(ascii: "/") ? value : value + "/"
      }
    #endif
    #if os(Android)
      return "/data/local/tmp/"
    #else
      return "/tmp/"
    #endif
  }

  /// The process's current directory, or `nil` if it cannot be read.
  static var currentDirectoryPath: String? {
    #if os(Windows)
      return nil
    #else
      var capacity = 1024
      while true {
        var buffer = [CChar](repeating: 0, count: capacity)
        if getcwd(&buffer, buffer.count) != nil {
          return string(fromCString: buffer)
        }
        guard errno == ERANGE else { return nil }
        capacity *= 2
      }
    #endif
  }

  /// The current user's home directory, which a path beginning `~/` starts from, found as
  /// Foundation finds it: `CFFIXED_USER_HOME`, then the user database's entry for the user, then
  /// `HOME`, then `/var/empty`. A simulator reads `CFFIXED_USER_HOME` or `HOME` first.
  ///
  /// A process whose effective user is root is taken to be its real user, as Foundation does.
  static var homeDirectoryPath: String {
    #if os(Windows)
      return "/var/empty"
    #else
      #if targetEnvironment(simulator)
        if let home = getenv("CFFIXED_USER_HOME") ?? getenv("HOME") {
          return standardizedHome(String(cString: home))
        }
      #endif
      if let home = environmentValue(securelyNamed: "CFFIXED_USER_HOME") {
        return standardizedHome(home)
      }
      #if !os(WASI)
        var uid = geteuid()
        if uid == 0 {
          uid = getuid()
        }
        if let home = userEntryHome({ getpwuid_r(uid, $0, $1, $2, $3) }) {
          return standardizedHome(home)
        }
      #endif
      if let home = getenv("HOME") {
        return standardizedHome(String(cString: home))
      }
      return "/var/empty"
    #endif
  }

  /// The home directory of the user named `user`, which a path beginning `~user/` starts from, or
  /// `nil` if there is no such user.
  static func homeDirectoryPath(forUser user: String) -> String? {
    #if os(Windows) || os(WASI)
      return nil
    #else
      if let home = environmentValue(securelyNamed: "CFFIXED_USER_HOME") {
        return standardizedHome(home)
      }
      return userEntryHome { getpwnam_r(user, $0, $1, $2, $3) }.map(standardizedHome)
    #endif
  }

  #if !os(Windows) && !os(WASI)
    /// The home directory in the user database entry `lookUp` finds, as `getpwuid_r` or
    /// `getpwnam_r` finds one.
    private static func userEntryHome(
      _ lookUp: (
        UnsafeMutablePointer<passwd>,
        UnsafeMutablePointer<CChar>,
        Int,
        UnsafeMutablePointer<UnsafeMutablePointer<passwd>?>
      ) -> Int32
    ) -> String? {
      var entry = passwd()
      var result: UnsafeMutablePointer<passwd>?
      var buffer = [CChar](repeating: 0, count: 16 * 1024)
      let status = buffer.withUnsafeMutableBufferPointer { buffer in
        lookUp(&entry, buffer.baseAddress!, buffer.count, &result)
      }
      guard status == 0, result != nil else { return nil }
      // Bionic declares `pw_dir` as possibly null.
      let directory: UnsafeMutablePointer<CChar>? = entry.pw_dir
      return directory.map { String(cString: $0) }
    }
  #endif

  private static func standardizedHome(_ path: String) -> String {
    let path = FilePath.expandingTilde(path)
    return path.utf8.first == UInt8(ascii: "/") ? FilePath.standardizingAbsolutePath(path) : path
  }

  /// Whether a file is at `path`, following a symbolic link to what it names.
  static func fileExists(atPath path: String) -> Bool {
    #if os(Windows)
      return false
    #else
      var status = stat()
      return stat(path, &status) == 0
    #endif
  }

  /// Whether anything is at `path` itself, a symbolic link included whatever it names.
  static func entryExists(atPath path: String) -> Bool {
    #if os(Windows)
      return false
    #else
      var status = stat()
      return lstat(path, &status) == 0
    #endif
  }

  /// What the symbolic link at `path` holds, or `nil` if there is no symbolic link there.
  static func symbolicLinkDestination(atPath path: String) -> String? {
    #if os(Windows)
      return nil
    #else
      var capacity = 1024
      while true {
        var buffer = [CChar](repeating: 0, count: capacity)
        let count = readlink(path, &buffer, buffer.count)
        guard count >= 0 else { return nil }
        if count < buffer.count {
          return String(
            decoding: buffer[..<count].map { UInt8(bitPattern: $0) },
            as: UTF8.self
          )
        }
        // It may not all have fit.
        capacity *= 2
      }
    #endif
  }

  /// The absolute path with every symbolic link in it resolved, or `nil` if any of its
  /// components does not exist.
  ///
  /// It is what Foundation reads a path through when it resolves symbolic links: the path the
  /// kernel has for the file on Darwin, and `realpath` elsewhere.
  static func resolvingSymbolicLinks(_ path: String) -> String? {
    #if os(Windows)
      return nil
    #else
      #if canImport(Darwin)
        if let fullPath = kernelFullPath(path) {
          return fullPath
        }
      #endif
      guard let resolved = realpath(path, nil) else { return nil }
      defer { free(resolved) }
      return String(cString: resolved)
    #endif
  }

  #if canImport(Darwin)
    /// The path the kernel has for the file at `path`, following a symbolic link at its end.
    private static func kernelFullPath(_ path: String) -> String? {
      var attributes = attrlist()
      attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
      attributes.commonattr = attrgroup_t(ATTR_CMN_FULLPATH)
      // The returned length, then the attribute's reference to its data, then the data.
      let lengthSize = MemoryLayout<UInt32>.size
      let byteCount = lengthSize + MemoryLayout<attrreference_t>.size + Int(PATH_MAX)
      let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
      defer { buffer.deallocate() }
      guard getattrlist(path, &attributes, buffer, byteCount, 0) == 0 else { return nil }
      let reference = (buffer + lengthSize).loadUnaligned(as: attrreference_t.self)
      guard reference.attr_length > 0 else { return nil }
      // The offset counts from the reference itself.
      let data = buffer + lengthSize + Int(reference.attr_dataoffset)
      return String(cString: data.assumingMemoryBound(to: CChar.self))
    }
  #endif

  /// Removes the file at `path`, returning whether there was one to remove.
  @discardableResult
  static func removeFile(atPath path: String) -> Bool {
    #if os(Windows)
      return false
    #else
      return unlink(path) == 0
    #endif
  }

  #if !os(Windows)
    /// The value of an environment variable, unless the process runs with privileges it did not
    /// start with, where the environment cannot be trusted.
    private static func environmentValue(securelyNamed name: String) -> String? {
      #if canImport(Glibc)
        // What `secure_getenv`, which Swift's Glibc module leaves out, checks for a process that
        // is not being audited: that it runs as the user and group that started it.
        guard getuid() == geteuid(), getgid() == getegid() else { return nil }
      #elseif !canImport(Android) && !os(WASI)
        guard issetugid() == 0 else { return nil }
      #endif
      return getenv(name).map { String(cString: $0) }
    }
  #endif

  private static func string(fromCString buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
