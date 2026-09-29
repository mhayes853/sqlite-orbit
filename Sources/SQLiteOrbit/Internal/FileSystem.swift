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
        let path = buffer.withUnsafeMutableBufferPointer { buffer -> String? in
          guard confstr(_CS_DARWIN_USER_TEMP_DIR, buffer.baseAddress, buffer.count) > 0 else {
            return nil
          }
          return String(cString: buffer.baseAddress!)
        }
        if let path {
          return path
        }
      }
    #endif
    #if !os(WASI) && !os(Windows)
      return temporaryDirectoryPath(environmentValue: environmentValue(securelyNamed: "TMPDIR"))
    #else
      return temporaryDirectoryPath(environmentValue: nil)
    #endif
  }

  /// The temporary directory `TMPDIR` names, given a slash at its end if it has none, or the
  /// platform's own if `TMPDIR` is not set, as Foundation has it outside Darwin.
  ///
  /// - Parameter value: The value of `TMPDIR`, or `nil` if it is not set.
  static func temporaryDirectoryPath(environmentValue value: String?) -> String {
    if let value {
      return value.utf8.last == UInt8(ascii: "/") ? value : value + "/"
    }
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
        let path = buffer.withUnsafeMutableBufferPointer { buffer -> String? in
          guard getcwd(buffer.baseAddress, buffer.count) != nil else { return nil }
          return String(cString: buffer.baseAddress!)
        }
        if let path {
          return path
        }
        guard errno == ERANGE else { return nil }
        capacity *= 2
      }
    #endif
  }

  // Darwin's Foundation takes a tilde at the start of a file path for an ordinary component,
  // where the others expand it, so only they need to know where a home directory is.
  #if !canImport(Darwin)
    /// The current user's home directory, which a path beginning `~/` starts from, found as
    /// Foundation finds it: `CFFIXED_USER_HOME`, then the user database's entry for the user, then
    /// `HOME`, then `/var/empty`.
    ///
    /// A process whose effective user is root is taken to be its real user, as Foundation does.
    static var homeDirectoryPath: String {
      #if os(Windows)
        return "/var/empty"
      #else
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
  #endif

  /// Whether a file is at `path`, following a symbolic link to what it names.
  static func fileExists(atPath path: String) -> Bool {
    #if os(Windows)
      return false
    #else
      return status(atPath: path, followingSymbolicLink: true) != nil
    #endif
  }

  /// What is at a path itself, rather than what a symbolic link there names.
  enum Entry {
    /// A symbolic link.
    case symbolicLink

    /// Anything else: a file, a directory, a socket.
    case other
  }

  /// What is at `path` itself, a symbolic link included whatever it names, or `nil` if nothing
  /// is there.
  static func entry(atPath path: String) -> Entry? {
    #if os(Windows)
      return nil
    #else
      guard let status = status(atPath: path, followingSymbolicLink: false) else { return nil }
      return mode_t(status.st_mode) & S_IFMT == S_IFLNK ? .symbolicLink : .other
    #endif
  }

  /// What the symbolic link at `path` holds, or `nil` if there is no symbolic link there.
  static func symbolicLinkDestination(atPath path: String) -> String? {
    #if os(Windows)
      return nil
    #else
      var capacity = 1024
      while true {
        // What `readlink` returned, which is negative if it failed, and whether that all fit.
        var count = -1
        var didFit = false
        let destination = String(unsafeUninitializedCapacity: capacity) { buffer in
          count = buffer.withMemoryRebound(to: CChar.self) {
            readlink(path, $0.baseAddress!, $0.count)
          }
          didFit = count >= 0 && count < buffer.count
          return didFit ? count : 0
        }
        guard count >= 0 else { return nil }
        if didFit {
          return destination
        }
        // It may not all have fit.
        capacity *= 2
      }
    #endif
  }

  #if !os(Windows)
    /// The status of what is at `path`, or of what a symbolic link there names if
    /// `followingSymbolicLink`, or `nil` if it cannot be looked up, as when nothing is there.
    private static func status(atPath path: String, followingSymbolicLink: Bool) -> stat? {
      var status = stat()
      let result = followingSymbolicLink ? stat(path, &status) : lstat(path, &status)
      return result == 0 ? status : nil
    }
  #endif

  /// The absolute path with every symbolic link in it resolved, or `nil` if any of its
  /// components does not exist.
  ///
  /// It is what Foundation reads a path through when it resolves symbolic links: on Darwin, the
  /// path the kernel has for the file, or failing that each component resolved in turn, and
  /// `realpath` elsewhere.
  static func resolvingSymbolicLinks(_ path: String) -> String? {
    #if os(Windows)
      return nil
    #elseif canImport(Darwin)
      if path.utf8.first == UInt8(ascii: "/"), let fullPath = kernelFullPath(path) {
        return fullPath
      }
      return resolvingSymbolicLinksByComponent(path)
    #else
      guard let resolved = realpath(path, nil) else { return nil }
      defer { free(resolved) }
      return String(cString: resolved)
    #endif
  }

  #if canImport(Darwin)
    /// The path with each symbolic link replaced by its destination, one component at a time, as
    /// Darwin's Foundation resolves it when the kernel has no full path for it.
    ///
    /// Every component must exist. Darwin's `realpath` differs here: it takes a `..` after a link
    /// to a file as the file's directory, where this fails as Foundation does.
    private static func resolvingSymbolicLinksByComponent(_ path: String) -> String? {
      let slash = UInt8(ascii: "/")
      var utf8 = Array(path.utf8)
      var scan = 0
      var linkCount = 0
      while true {
        // Where the component began, at the slash before it, which a relative link keeps.
        let componentStart = scan
        while scan < utf8.count, utf8[scan] == slash { scan += 1 }
        while scan < utf8.count, utf8[scan] != slash { scan += 1 }
        let prefix = String(decoding: utf8[..<scan], as: UTF8.self)
        guard let entry = entry(atPath: prefix) else { return nil }
        if entry == .symbolicLink, let destination = symbolicLinkDestination(atPath: prefix),
          !destination.isEmpty
        {
          // Darwin's `MAXSYMLINKS`.
          guard linkCount <= 32 else { return nil }
          linkCount += 1
          let isAbsolute = destination.utf8.first == slash
          utf8 =
            Array(utf8[..<(isAbsolute ? 0 : componentStart + 1)]) + Array(destination.utf8)
            + Array(utf8[scan...])
          scan = isAbsolute ? 0 : componentStart
        } else if scan == utf8.count {
          return String(decoding: utf8, as: UTF8.self)
        }
      }
    }

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
  ///
  /// A failure leaves `errno` as `unlink` left it, as `ENOENT` when nothing is there.
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
}

#if canImport(Darwin) || os(Linux) || os(Android)
  // What the coordination directory is kept with, where there are processes to coordinate. Each
  // call returns what the C call returned and leaves `errno` as the C call left it, or throws a
  // ``UnixSystemError`` carrying it.
  extension FileSystem {
    /// Renames the file at `source` over the one at `destination`, in one step, so a reader finds
    /// one file or the other and never neither.
    static func renameFile(atPath source: String, toPath destination: String) -> Bool {
      rename(source, destination) == 0
    }

    /// Sets the access and modification times of the file at `path`, whatever kind it is, to
    /// now, which needs the caller to own it or be able to write to it.
    static func touchFile(atPath path: String) -> Bool {
      utimes(path, nil) == 0
    }

    /// Removes the directory at `path` if it is empty.
    ///
    /// A directory that is not empty fails with `ENOTEMPTY`, or on some systems `EEXIST`, and one
    /// that is not there with `ENOENT`.
    static func removeDirectory(atPath path: String) -> Bool {
      rmdir(path) == 0
    }

    /// Creates the directory at `path`, and each missing directory above it, as
    /// `FileManager.createDirectory(atPath:withIntermediateDirectories:)` does. A directory
    /// already there, including one another process creates meanwhile, is left as it is.
    ///
    /// - Throws: A ``UnixSystemError`` if a directory cannot be created, or if something other
    ///   than a directory is in the way, with `EEXIST`.
    static func createDirectory(atPath path: String) throws {
      if mkdir(path, 0o777) == 0 { return }
      switch errno {
      case EEXIST:
        break
      case ENOENT:
        let parent = FilePath.deletingLastComponent(of: path)
        guard parent != FilePath.droppingTrailingSlashes(path), !parent.isEmpty else {
          throw UnixSystemError.last("mkdir")
        }
        try Self.createDirectory(atPath: parent)
        if mkdir(path, 0o777) == 0 { return }
        guard errno == EEXIST else { throw UnixSystemError.last("mkdir") }
      default:
        throw UnixSystemError.last("mkdir")
      }
      guard let status = status(atPath: path, followingSymbolicLink: true) else {
        throw UnixSystemError.last("stat")
      }
      guard mode_t(status.st_mode) & S_IFMT == S_IFDIR else {
        throw UnixSystemError(operation: "mkdir", code: EEXIST)
      }
    }

    /// The names of what is in the directory at `path`, in no particular order, leaving out `.`
    /// and `..`.
    ///
    /// - Throws: A ``UnixSystemError`` if the directory cannot be read, with `ENOENT` if it is
    ///   not there.
    static func contentsOfDirectory(atPath path: String) throws -> [String] {
      guard let directory = opendir(path) else { throw UnixSystemError.last("opendir") }
      defer { closedir(directory) }
      var names: [String] = []
      while true {
        errno = 0
        guard let entry = readdir(directory) else {
          guard errno == 0 else { throw UnixSystemError.last("readdir") }
          return names
        }
        let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
          String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name != "." && name != ".." {
          names.append(name)
        }
      }
    }

    /// The names of what is in the directory at `path`, as ``contentsOfDirectory(atPath:)`` has
    /// them, or none if it cannot be read, as when it is gone.
    static func contentsOfDirectoryIfReadable(atPath path: String) -> [String] {
      (try? contentsOfDirectory(atPath: path)) ?? []
    }

    /// Everything in the file at `path`.
    ///
    /// - Throws: A ``UnixSystemError`` if it cannot be read, with `ENOENT` if nothing is there.
    static func contentsOfFile(atPath path: String) throws -> [UInt8] {
      let descriptor = try UnixDescriptor(UnixPlatform.openExistingFile(atPath: path), from: "open")
      var contents: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = buffer.withUnsafeMutableBytes {
          UnixPlatform.readBytes(from: descriptor.rawValue, into: $0)
        }
        guard count >= 0 else { throw UnixSystemError.last("read") }
        guard count > 0 else { return contents }
        contents.append(contentsOf: buffer[..<count])
      }
    }

    /// Writes `bytes` to the file at `path`, creating it if it is not there and replacing what it
    /// held if it is, in place, as `Data.write(to:)` does without `.atomic`.
    ///
    /// - Throws: A ``UnixSystemError`` if it cannot be written, with `ENOENT` if its directory is
    ///   not there.
    static func writeFile(_ bytes: [UInt8], atPath path: String) throws {
      let descriptor = try UnixDescriptor(
        open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666),
        from: "open"
      )
      var written = 0
      while written < bytes.count {
        let count = bytes.withUnsafeBytes {
          UnixPlatform.writeBytes(
            UnsafeRawBufferPointer(rebasing: $0[written...]),
            to: descriptor.rawValue
          )
        }
        if count < 0 {
          guard errno == EINTR else { throw UnixSystemError.last("write") }
          continue
        }
        written += count
      }
    }

    /// How long before now the file at `path` itself, not what a symbolic link there names, was
    /// last modified, by the system's clock, or `nil` if it cannot be looked up.
    ///
    /// A file modified after now, by a clock set back, has a negative age.
    static func ageOfFile(atPath path: String) -> Duration? {
      var now = timespec()
      guard let status = status(atPath: path, followingSymbolicLink: false),
        clock_gettime(CLOCK_REALTIME, &now) == 0
      else { return nil }
      #if canImport(Darwin)
        let modified = status.st_mtimespec
      #else
        let modified = status.st_mtim
      #endif
      return .seconds(Int64(now.tv_sec) - Int64(modified.tv_sec))
        + .nanoseconds(Int64(now.tv_nsec) - Int64(modified.tv_nsec))
    }
  }
#endif
