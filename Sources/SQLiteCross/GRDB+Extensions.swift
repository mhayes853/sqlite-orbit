#if GRDB
  import GRDB
  import GRDBSQLite
  public import StructuredQueriesSQLite

  extension Configuration {
    /// Installs `extensions` on every connection opened with this configuration.
    ///
    /// A collating sequence or function is only known to the connection it was installed on. A
    /// `DatabasePool` opens connections as it needs them, so installing on one connection leaves
    /// queries on every other connection failing with "no such collation sequence". Registering
    /// through the configuration covers connections opened later, too.
    ///
    /// ```swift
    /// var extensions = DatabaseExtensions()
    /// extensions.add(collation: $localized)
    ///
    /// var configuration = Configuration()
    /// configuration.register(extensions)
    ///
    /// let database = CrossProcessDatabase(
    ///   writer: try DatabasePool(path: path, configuration: configuration)
    /// )
    /// ```
    public mutating func register(_ extensions: DatabaseExtensions) {
      guard !extensions.isEmpty else { return }
      prepareDatabase { database in
        for collation in extensions.collations {
          database.install(collation: collation)
        }
      }
    }
  }

  extension Database {
    /// Installs a Swift-implemented collating sequence on this connection.
    ///
    /// Prefer ``GRDB/Configuration/register(_:)``, which covers every connection a pool opens.
    public func install(collation: some StructuredQueriesSQLiteCore.DatabaseCollation) {
      sqlite3_create_collation_v2(
        sqliteConnection,
        collation.name,
        SQLITE_UTF8,
        // SQLite owns the comparator for as long as the collation is registered, and hands it back
        // on every comparison. The destructor below balances this retain.
        Unmanaged.passRetained(DatabaseCollationBox(collation)).toOpaque(),
        { box, lhsCount, lhs, rhsCount, rhs in
          let collation = Unmanaged<DatabaseCollationBox>
            .fromOpaque(box!)
            .takeUnretainedValue()
            .collation
          switch collation.compare(
            UnsafeRawBufferPointer(start: lhs, count: Int(lhsCount)),
            UnsafeRawBufferPointer(start: rhs, count: Int(rhsCount))
          ) {
          case .ascending: return -1
          case .same: return 0
          case .descending: return 1
          }
        },
        { box in
          guard let box else { return }
          Unmanaged<DatabaseCollationBox>.fromOpaque(box).release()
        }
      )
    }
  }

  private final class DatabaseCollationBox {
    let collation: any StructuredQueriesSQLiteCore.DatabaseCollation

    init(_ collation: any StructuredQueriesSQLiteCore.DatabaseCollation) {
      self.collation = collation
    }
  }
#endif
