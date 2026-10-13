#if canImport(Foundation) && canImport(Dispatch)
  import SQLiteOrbit

  public struct ResultCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public var primaryResultCode: Self { Self(rawValue: rawValue & 0xff) }
  }

  public struct DatabaseError: Error, Sendable, CustomStringConvertible {
    public let extendedResultCode: ResultCode
    public var resultCode: ResultCode { extendedResultCode.primaryResultCode }
    public let message: String?
    public let sql: String?
    public let arguments: StatementArguments?
    public init(
      resultCode: ResultCode = .SQLITE_ERROR,
      message: String? = nil,
      sql: String? = nil,
      arguments: StatementArguments? = nil
    ) {
      self.extendedResultCode = resultCode
      self.message = message
      self.sql = sql
      self.arguments = arguments
    }
    init(_ error: SQLiteError, arguments: StatementArguments? = nil) {
      self.init(
        resultCode: .init(rawValue: error.code.rawValue),
        message: error.message,
        sql: error.sql,
        arguments: arguments
      )
    }
    public var isInterruptionError: Bool {
      resultCode == .SQLITE_INTERRUPT || resultCode == .SQLITE_ABORT
    }
    public var description: String {
      "SQLite error \(extendedResultCode.rawValue)" + (sql.map { " with statement `\($0)`" } ?? "")
        + (message.map { ": \($0)" } ?? "")
    }
  }
  func translate<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let error as SQLiteError { throw DatabaseError(error) }
  }
  func translate<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let error as SQLiteError { throw DatabaseError(error) }
  }
  public func ~= (code: ResultCode, error: any Error) -> Bool {
    guard let error = error as? DatabaseError else { return false }
    return code.rawValue < 256 ? error.resultCode == code : error.extendedResultCode == code
  }

  // GRDB and SQLite expose these exact constant names.
  // swift-format-ignore: AlwaysUseLowerCamelCase
  extension ResultCode {
    public static let SQLITE_OK = Self(rawValue: 0)
    public static let SQLITE_ERROR = Self(rawValue: 1)
    public static let SQLITE_INTERNAL = Self(rawValue: 2)
    public static let SQLITE_PERM = Self(rawValue: 3)
    public static let SQLITE_ABORT = Self(rawValue: 4)
    public static let SQLITE_BUSY = Self(rawValue: 5)
    public static let SQLITE_LOCKED = Self(rawValue: 6)
    public static let SQLITE_NOMEM = Self(rawValue: 7)
    public static let SQLITE_READONLY = Self(rawValue: 8)
    public static let SQLITE_INTERRUPT = Self(rawValue: 9)
    public static let SQLITE_IOERR = Self(rawValue: 10)
    public static let SQLITE_CORRUPT = Self(rawValue: 11)
    public static let SQLITE_NOTFOUND = Self(rawValue: 12)
    public static let SQLITE_FULL = Self(rawValue: 13)
    public static let SQLITE_CANTOPEN = Self(rawValue: 14)
    public static let SQLITE_PROTOCOL = Self(rawValue: 15)
    public static let SQLITE_EMPTY = Self(rawValue: 16)
    public static let SQLITE_SCHEMA = Self(rawValue: 17)
    public static let SQLITE_TOOBIG = Self(rawValue: 18)
    public static let SQLITE_CONSTRAINT = Self(rawValue: 19)
    public static let SQLITE_MISMATCH = Self(rawValue: 20)
    public static let SQLITE_MISUSE = Self(rawValue: 21)
    public static let SQLITE_NOLFS = Self(rawValue: 22)
    public static let SQLITE_AUTH = Self(rawValue: 23)
    public static let SQLITE_FORMAT = Self(rawValue: 24)
    public static let SQLITE_RANGE = Self(rawValue: 25)
    public static let SQLITE_NOTADB = Self(rawValue: 26)
    public static let SQLITE_NOTICE = Self(rawValue: 27)
    public static let SQLITE_WARNING = Self(rawValue: 28)
    public static let SQLITE_ROW = Self(rawValue: 100)
    public static let SQLITE_DONE = Self(rawValue: 101)
    public static let SQLITE_ERROR_MISSING_COLLSEQ = Self(
      rawValue: (SQLITE_ERROR.rawValue | (1 << 8))
    )
    public static let SQLITE_ERROR_RETRY = Self(rawValue: (SQLITE_ERROR.rawValue | (2 << 8)))
    public static let SQLITE_ERROR_SNAPSHOT = Self(rawValue: (SQLITE_ERROR.rawValue | (3 << 8)))
    public static let SQLITE_IOERR_READ = Self(rawValue: (SQLITE_IOERR.rawValue | (1 << 8)))
    public static let SQLITE_IOERR_SHORT_READ = Self(rawValue: (SQLITE_IOERR.rawValue | (2 << 8)))
    public static let SQLITE_IOERR_WRITE = Self(rawValue: (SQLITE_IOERR.rawValue | (3 << 8)))
    public static let SQLITE_IOERR_FSYNC = Self(rawValue: (SQLITE_IOERR.rawValue | (4 << 8)))
    public static let SQLITE_IOERR_DIR_FSYNC = Self(rawValue: (SQLITE_IOERR.rawValue | (5 << 8)))
    public static let SQLITE_IOERR_TRUNCATE = Self(rawValue: (SQLITE_IOERR.rawValue | (6 << 8)))
    public static let SQLITE_IOERR_FSTAT = Self(rawValue: (SQLITE_IOERR.rawValue | (7 << 8)))
    public static let SQLITE_IOERR_UNLOCK = Self(rawValue: (SQLITE_IOERR.rawValue | (8 << 8)))
    public static let SQLITE_IOERR_RDLOCK = Self(rawValue: (SQLITE_IOERR.rawValue | (9 << 8)))
    public static let SQLITE_IOERR_DELETE = Self(rawValue: (SQLITE_IOERR.rawValue | (10 << 8)))
    public static let SQLITE_IOERR_BLOCKED = Self(rawValue: (SQLITE_IOERR.rawValue | (11 << 8)))
    public static let SQLITE_IOERR_NOMEM = Self(rawValue: (SQLITE_IOERR.rawValue | (12 << 8)))
    public static let SQLITE_IOERR_ACCESS = Self(rawValue: (SQLITE_IOERR.rawValue | (13 << 8)))
    public static let SQLITE_IOERR_CHECKRESERVEDLOCK = Self(
      rawValue: (SQLITE_IOERR.rawValue | (14 << 8))
    )
    public static let SQLITE_IOERR_LOCK = Self(rawValue: (SQLITE_IOERR.rawValue | (15 << 8)))
    public static let SQLITE_IOERR_CLOSE = Self(rawValue: (SQLITE_IOERR.rawValue | (16 << 8)))
    public static let SQLITE_IOERR_DIR_CLOSE = Self(rawValue: (SQLITE_IOERR.rawValue | (17 << 8)))
    public static let SQLITE_IOERR_SHMOPEN = Self(rawValue: (SQLITE_IOERR.rawValue | (18 << 8)))
    public static let SQLITE_IOERR_SHMSIZE = Self(rawValue: (SQLITE_IOERR.rawValue | (19 << 8)))
    public static let SQLITE_IOERR_SHMLOCK = Self(rawValue: (SQLITE_IOERR.rawValue | (20 << 8)))
    public static let SQLITE_IOERR_SHMMAP = Self(rawValue: (SQLITE_IOERR.rawValue | (21 << 8)))
    public static let SQLITE_IOERR_SEEK = Self(rawValue: (SQLITE_IOERR.rawValue | (22 << 8)))
    public static let SQLITE_IOERR_DELETE_NOENT = Self(
      rawValue: (SQLITE_IOERR.rawValue | (23 << 8))
    )
    public static let SQLITE_IOERR_MMAP = Self(rawValue: (SQLITE_IOERR.rawValue | (24 << 8)))
    public static let SQLITE_IOERR_GETTEMPPATH = Self(rawValue: (SQLITE_IOERR.rawValue | (25 << 8)))
    public static let SQLITE_IOERR_CONVPATH = Self(rawValue: (SQLITE_IOERR.rawValue | (26 << 8)))
    public static let SQLITE_IOERR_VNODE = Self(rawValue: (SQLITE_IOERR.rawValue | (27 << 8)))
    public static let SQLITE_IOERR_AUTH = Self(rawValue: (SQLITE_IOERR.rawValue | (28 << 8)))
    public static let SQLITE_IOERR_BEGIN_ATOMIC = Self(
      rawValue: (SQLITE_IOERR.rawValue | (29 << 8))
    )
    public static let SQLITE_IOERR_COMMIT_ATOMIC = Self(
      rawValue: (SQLITE_IOERR.rawValue | (30 << 8))
    )
    public static let SQLITE_IOERR_ROLLBACK_ATOMIC = Self(
      rawValue: (SQLITE_IOERR.rawValue | (31 << 8))
    )
    public static let SQLITE_IOERR_DATA = Self(rawValue: (SQLITE_IOERR.rawValue | (32 << 8)))
    public static let SQLITE_IOERR_CORRUPTFS = Self(rawValue: (SQLITE_IOERR.rawValue | (33 << 8)))
    public static let SQLITE_LOCKED_SHAREDCACHE = Self(
      rawValue: (SQLITE_LOCKED.rawValue | (1 << 8))
    )
    public static let SQLITE_LOCKED_VTAB = Self(rawValue: (SQLITE_LOCKED.rawValue | (2 << 8)))
    public static let SQLITE_BUSY_RECOVERY = Self(rawValue: (SQLITE_BUSY.rawValue | (1 << 8)))
    public static let SQLITE_BUSY_SNAPSHOT = Self(rawValue: (SQLITE_BUSY.rawValue | (2 << 8)))
    public static let SQLITE_BUSY_TIMEOUT = Self(rawValue: (SQLITE_BUSY.rawValue | (3 << 8)))
    public static let SQLITE_CANTOPEN_NOTEMPDIR = Self(
      rawValue: (SQLITE_CANTOPEN.rawValue | (1 << 8))
    )
    public static let SQLITE_CANTOPEN_ISDIR = Self(rawValue: (SQLITE_CANTOPEN.rawValue | (2 << 8)))
    public static let SQLITE_CANTOPEN_FULLPATH = Self(
      rawValue: (SQLITE_CANTOPEN.rawValue | (3 << 8))
    )
    public static let SQLITE_CANTOPEN_CONVPATH = Self(
      rawValue: (SQLITE_CANTOPEN.rawValue | (4 << 8))
    )
    public static let SQLITE_CANTOPEN_SYMLINK = Self(
      rawValue: (SQLITE_CANTOPEN.rawValue | (6 << 8))
    )
    public static let SQLITE_CORRUPT_VTAB = Self(rawValue: (SQLITE_CORRUPT.rawValue | (1 << 8)))
    public static let SQLITE_CORRUPT_SEQUENCE = Self(rawValue: (SQLITE_CORRUPT.rawValue | (2 << 8)))
    public static let SQLITE_CORRUPT_INDEX = Self(rawValue: (SQLITE_CORRUPT.rawValue | (3 << 8)))
    public static let SQLITE_READONLY_RECOVERY = Self(
      rawValue: (SQLITE_READONLY.rawValue | (1 << 8))
    )
    public static let SQLITE_READONLY_CANTLOCK = Self(
      rawValue: (SQLITE_READONLY.rawValue | (2 << 8))
    )
    public static let SQLITE_READONLY_ROLLBACK = Self(
      rawValue: (SQLITE_READONLY.rawValue | (3 << 8))
    )
    public static let SQLITE_READONLY_DBMOVED = Self(
      rawValue: (SQLITE_READONLY.rawValue | (4 << 8))
    )
    public static let SQLITE_READONLY_CANTINIT = Self(
      rawValue: (SQLITE_READONLY.rawValue | (5 << 8))
    )
    public static let SQLITE_READONLY_DIRECTORY = Self(
      rawValue: (SQLITE_READONLY.rawValue | (6 << 8))
    )
    public static let SQLITE_ABORT_ROLLBACK = Self(rawValue: (SQLITE_ABORT.rawValue | (2 << 8)))
    public static let SQLITE_CONSTRAINT_CHECK = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (1 << 8))
    )
    public static let SQLITE_CONSTRAINT_COMMITHOOK = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (2 << 8))
    )
    public static let SQLITE_CONSTRAINT_FOREIGNKEY = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (3 << 8))
    )
    public static let SQLITE_CONSTRAINT_FUNCTION = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (4 << 8))
    )
    public static let SQLITE_CONSTRAINT_NOTNULL = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (5 << 8))
    )
    public static let SQLITE_CONSTRAINT_PRIMARYKEY = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (6 << 8))
    )
    public static let SQLITE_CONSTRAINT_TRIGGER = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (7 << 8))
    )
    public static let SQLITE_CONSTRAINT_UNIQUE = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (8 << 8))
    )
    public static let SQLITE_CONSTRAINT_VTAB = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (9 << 8))
    )
    public static let SQLITE_CONSTRAINT_ROWID = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (10 << 8))
    )
    public static let SQLITE_CONSTRAINT_PINNED = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (11 << 8))
    )
    public static let SQLITE_CONSTRAINT_DATATYPE = Self(
      rawValue: (SQLITE_CONSTRAINT.rawValue | (12 << 8))
    )
    public static let SQLITE_NOTICE_RECOVER_WAL = Self(
      rawValue: (SQLITE_NOTICE.rawValue | (1 << 8))
    )
    public static let SQLITE_NOTICE_RECOVER_ROLLBACK = Self(
      rawValue: (SQLITE_NOTICE.rawValue | (2 << 8))
    )
    public static let SQLITE_WARNING_AUTOINDEX = Self(
      rawValue: (SQLITE_WARNING.rawValue | (1 << 8))
    )
    public static let SQLITE_AUTH_USER = Self(rawValue: (SQLITE_AUTH.rawValue | (1 << 8)))
    public static let SQLITE_OK_LOAD_PERMANENTLY = Self(rawValue: (SQLITE_OK.rawValue | (1 << 8)))
    public static let SQLITE_OK_SYMLINK = Self(rawValue: (SQLITE_OK.rawValue | (2 << 8)))
  }
  // swift-format-ignore: AlwaysUseLowerCamelCase
  extension DatabaseError {
    public static let SQLITE_OK = ResultCode.SQLITE_OK
    public static let SQLITE_ERROR = ResultCode.SQLITE_ERROR
    public static let SQLITE_INTERNAL = ResultCode.SQLITE_INTERNAL
    public static let SQLITE_PERM = ResultCode.SQLITE_PERM
    public static let SQLITE_ABORT = ResultCode.SQLITE_ABORT
    public static let SQLITE_BUSY = ResultCode.SQLITE_BUSY
    public static let SQLITE_LOCKED = ResultCode.SQLITE_LOCKED
    public static let SQLITE_NOMEM = ResultCode.SQLITE_NOMEM
    public static let SQLITE_READONLY = ResultCode.SQLITE_READONLY
    public static let SQLITE_INTERRUPT = ResultCode.SQLITE_INTERRUPT
    public static let SQLITE_IOERR = ResultCode.SQLITE_IOERR
    public static let SQLITE_CORRUPT = ResultCode.SQLITE_CORRUPT
    public static let SQLITE_NOTFOUND = ResultCode.SQLITE_NOTFOUND
    public static let SQLITE_FULL = ResultCode.SQLITE_FULL
    public static let SQLITE_CANTOPEN = ResultCode.SQLITE_CANTOPEN
    public static let SQLITE_PROTOCOL = ResultCode.SQLITE_PROTOCOL
    public static let SQLITE_EMPTY = ResultCode.SQLITE_EMPTY
    public static let SQLITE_SCHEMA = ResultCode.SQLITE_SCHEMA
    public static let SQLITE_TOOBIG = ResultCode.SQLITE_TOOBIG
    public static let SQLITE_CONSTRAINT = ResultCode.SQLITE_CONSTRAINT
    public static let SQLITE_MISMATCH = ResultCode.SQLITE_MISMATCH
    public static let SQLITE_MISUSE = ResultCode.SQLITE_MISUSE
    public static let SQLITE_NOLFS = ResultCode.SQLITE_NOLFS
    public static let SQLITE_AUTH = ResultCode.SQLITE_AUTH
    public static let SQLITE_FORMAT = ResultCode.SQLITE_FORMAT
    public static let SQLITE_RANGE = ResultCode.SQLITE_RANGE
    public static let SQLITE_NOTADB = ResultCode.SQLITE_NOTADB
    public static let SQLITE_NOTICE = ResultCode.SQLITE_NOTICE
    public static let SQLITE_WARNING = ResultCode.SQLITE_WARNING
    public static let SQLITE_ROW = ResultCode.SQLITE_ROW
    public static let SQLITE_DONE = ResultCode.SQLITE_DONE
    public static let SQLITE_ERROR_MISSING_COLLSEQ = ResultCode.SQLITE_ERROR_MISSING_COLLSEQ
    public static let SQLITE_ERROR_RETRY = ResultCode.SQLITE_ERROR_RETRY
    public static let SQLITE_ERROR_SNAPSHOT = ResultCode.SQLITE_ERROR_SNAPSHOT
    public static let SQLITE_IOERR_READ = ResultCode.SQLITE_IOERR_READ
    public static let SQLITE_IOERR_SHORT_READ = ResultCode.SQLITE_IOERR_SHORT_READ
    public static let SQLITE_IOERR_WRITE = ResultCode.SQLITE_IOERR_WRITE
    public static let SQLITE_IOERR_FSYNC = ResultCode.SQLITE_IOERR_FSYNC
    public static let SQLITE_IOERR_DIR_FSYNC = ResultCode.SQLITE_IOERR_DIR_FSYNC
    public static let SQLITE_IOERR_TRUNCATE = ResultCode.SQLITE_IOERR_TRUNCATE
    public static let SQLITE_IOERR_FSTAT = ResultCode.SQLITE_IOERR_FSTAT
    public static let SQLITE_IOERR_UNLOCK = ResultCode.SQLITE_IOERR_UNLOCK
    public static let SQLITE_IOERR_RDLOCK = ResultCode.SQLITE_IOERR_RDLOCK
    public static let SQLITE_IOERR_DELETE = ResultCode.SQLITE_IOERR_DELETE
    public static let SQLITE_IOERR_BLOCKED = ResultCode.SQLITE_IOERR_BLOCKED
    public static let SQLITE_IOERR_NOMEM = ResultCode.SQLITE_IOERR_NOMEM
    public static let SQLITE_IOERR_ACCESS = ResultCode.SQLITE_IOERR_ACCESS
    public static let SQLITE_IOERR_CHECKRESERVEDLOCK = ResultCode.SQLITE_IOERR_CHECKRESERVEDLOCK
    public static let SQLITE_IOERR_LOCK = ResultCode.SQLITE_IOERR_LOCK
    public static let SQLITE_IOERR_CLOSE = ResultCode.SQLITE_IOERR_CLOSE
    public static let SQLITE_IOERR_DIR_CLOSE = ResultCode.SQLITE_IOERR_DIR_CLOSE
    public static let SQLITE_IOERR_SHMOPEN = ResultCode.SQLITE_IOERR_SHMOPEN
    public static let SQLITE_IOERR_SHMSIZE = ResultCode.SQLITE_IOERR_SHMSIZE
    public static let SQLITE_IOERR_SHMLOCK = ResultCode.SQLITE_IOERR_SHMLOCK
    public static let SQLITE_IOERR_SHMMAP = ResultCode.SQLITE_IOERR_SHMMAP
    public static let SQLITE_IOERR_SEEK = ResultCode.SQLITE_IOERR_SEEK
    public static let SQLITE_IOERR_DELETE_NOENT = ResultCode.SQLITE_IOERR_DELETE_NOENT
    public static let SQLITE_IOERR_MMAP = ResultCode.SQLITE_IOERR_MMAP
    public static let SQLITE_IOERR_GETTEMPPATH = ResultCode.SQLITE_IOERR_GETTEMPPATH
    public static let SQLITE_IOERR_CONVPATH = ResultCode.SQLITE_IOERR_CONVPATH
    public static let SQLITE_IOERR_VNODE = ResultCode.SQLITE_IOERR_VNODE
    public static let SQLITE_IOERR_AUTH = ResultCode.SQLITE_IOERR_AUTH
    public static let SQLITE_IOERR_BEGIN_ATOMIC = ResultCode.SQLITE_IOERR_BEGIN_ATOMIC
    public static let SQLITE_IOERR_COMMIT_ATOMIC = ResultCode.SQLITE_IOERR_COMMIT_ATOMIC
    public static let SQLITE_IOERR_ROLLBACK_ATOMIC = ResultCode.SQLITE_IOERR_ROLLBACK_ATOMIC
    public static let SQLITE_IOERR_DATA = ResultCode.SQLITE_IOERR_DATA
    public static let SQLITE_IOERR_CORRUPTFS = ResultCode.SQLITE_IOERR_CORRUPTFS
    public static let SQLITE_LOCKED_SHAREDCACHE = ResultCode.SQLITE_LOCKED_SHAREDCACHE
    public static let SQLITE_LOCKED_VTAB = ResultCode.SQLITE_LOCKED_VTAB
    public static let SQLITE_BUSY_RECOVERY = ResultCode.SQLITE_BUSY_RECOVERY
    public static let SQLITE_BUSY_SNAPSHOT = ResultCode.SQLITE_BUSY_SNAPSHOT
    public static let SQLITE_BUSY_TIMEOUT = ResultCode.SQLITE_BUSY_TIMEOUT
    public static let SQLITE_CANTOPEN_NOTEMPDIR = ResultCode.SQLITE_CANTOPEN_NOTEMPDIR
    public static let SQLITE_CANTOPEN_ISDIR = ResultCode.SQLITE_CANTOPEN_ISDIR
    public static let SQLITE_CANTOPEN_FULLPATH = ResultCode.SQLITE_CANTOPEN_FULLPATH
    public static let SQLITE_CANTOPEN_CONVPATH = ResultCode.SQLITE_CANTOPEN_CONVPATH
    public static let SQLITE_CANTOPEN_SYMLINK = ResultCode.SQLITE_CANTOPEN_SYMLINK
    public static let SQLITE_CORRUPT_VTAB = ResultCode.SQLITE_CORRUPT_VTAB
    public static let SQLITE_CORRUPT_SEQUENCE = ResultCode.SQLITE_CORRUPT_SEQUENCE
    public static let SQLITE_CORRUPT_INDEX = ResultCode.SQLITE_CORRUPT_INDEX
    public static let SQLITE_READONLY_RECOVERY = ResultCode.SQLITE_READONLY_RECOVERY
    public static let SQLITE_READONLY_CANTLOCK = ResultCode.SQLITE_READONLY_CANTLOCK
    public static let SQLITE_READONLY_ROLLBACK = ResultCode.SQLITE_READONLY_ROLLBACK
    public static let SQLITE_READONLY_DBMOVED = ResultCode.SQLITE_READONLY_DBMOVED
    public static let SQLITE_READONLY_CANTINIT = ResultCode.SQLITE_READONLY_CANTINIT
    public static let SQLITE_READONLY_DIRECTORY = ResultCode.SQLITE_READONLY_DIRECTORY
    public static let SQLITE_ABORT_ROLLBACK = ResultCode.SQLITE_ABORT_ROLLBACK
    public static let SQLITE_CONSTRAINT_CHECK = ResultCode.SQLITE_CONSTRAINT_CHECK
    public static let SQLITE_CONSTRAINT_COMMITHOOK = ResultCode.SQLITE_CONSTRAINT_COMMITHOOK
    public static let SQLITE_CONSTRAINT_FOREIGNKEY = ResultCode.SQLITE_CONSTRAINT_FOREIGNKEY
    public static let SQLITE_CONSTRAINT_FUNCTION = ResultCode.SQLITE_CONSTRAINT_FUNCTION
    public static let SQLITE_CONSTRAINT_NOTNULL = ResultCode.SQLITE_CONSTRAINT_NOTNULL
    public static let SQLITE_CONSTRAINT_PRIMARYKEY = ResultCode.SQLITE_CONSTRAINT_PRIMARYKEY
    public static let SQLITE_CONSTRAINT_TRIGGER = ResultCode.SQLITE_CONSTRAINT_TRIGGER
    public static let SQLITE_CONSTRAINT_UNIQUE = ResultCode.SQLITE_CONSTRAINT_UNIQUE
    public static let SQLITE_CONSTRAINT_VTAB = ResultCode.SQLITE_CONSTRAINT_VTAB
    public static let SQLITE_CONSTRAINT_ROWID = ResultCode.SQLITE_CONSTRAINT_ROWID
    public static let SQLITE_CONSTRAINT_PINNED = ResultCode.SQLITE_CONSTRAINT_PINNED
    public static let SQLITE_CONSTRAINT_DATATYPE = ResultCode.SQLITE_CONSTRAINT_DATATYPE
    public static let SQLITE_NOTICE_RECOVER_WAL = ResultCode.SQLITE_NOTICE_RECOVER_WAL
    public static let SQLITE_NOTICE_RECOVER_ROLLBACK = ResultCode.SQLITE_NOTICE_RECOVER_ROLLBACK
    public static let SQLITE_WARNING_AUTOINDEX = ResultCode.SQLITE_WARNING_AUTOINDEX
    public static let SQLITE_AUTH_USER = ResultCode.SQLITE_AUTH_USER
    public static let SQLITE_OK_LOAD_PERMANENTLY = ResultCode.SQLITE_OK_LOAD_PERMANENTLY
    public static let SQLITE_OK_SYMLINK = ResultCode.SQLITE_OK_SYMLINK
  }
#endif
