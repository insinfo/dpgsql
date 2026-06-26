/// The state of a PreparedStatement.
/// Porting PreparedStatement.cs (enum PreparedState)
enum PreparedState {
  /// The statement hasn't been prepared yet, nor is it in the process of being prepared.
  notPrepared,

  /// The statement is in the process of being prepared.
  beingPrepared,

  /// The statement has been fully prepared and can be executed.
  prepared,

  /// The statement is in the process of being unprepared.
  beingUnprepared,

  /// The statement has been unprepared and is no longer usable.
  unprepared,

  /// The statement was invalidated because e.g. table schema has changed since preparation.
  invalidated,
}

/// Internally represents a statement that has been prepared, is in the process of being prepared,
/// or is a candidate for preparation (i.e. awaiting further usages).
/// Porting PreparedStatement.cs
class PreparedStatement {
  PreparedStatement({
    required this.manager,
    required this.sql,
    required this.isExplicit,
  });

  final PreparedStatementManager manager;
  final String sql;
  final bool isExplicit;

  String? name;
  PreparedState state = PreparedState.notPrepared;

  /// Number of times this statement has been used.
  int usages = 0;

  /// If this statement is about to be prepared, but replaces a previous statement which needs to be closed,
  /// this holds the reference to the previous statement.
  PreparedStatement? statementBeingReplaced;

  /// Index in auto-prepared statements array.
  int autoPreparedSlotIndex = -1;

  /// Timestamp of last usage for LRU eviction.
  int lastUsed = 0;

  /// Parameter type OIDs for prepared statement matching.
  List<int>? _parameterOids;

  bool get isPrepared =>
      state == PreparedState.prepared || state == PreparedState.invalidated;

  void refreshLastUsed() {
    lastUsed = DateTime.now().microsecondsSinceEpoch;
  }

  void setParamTypes(List<int> oids) {
    _parameterOids = List.from(oids);
  }

  bool doParametersMatch(List<int> oids) {
    if (_parameterOids == null) return false;
    if (_parameterOids!.length != oids.length) return false;
    for (int i = 0; i < _parameterOids!.length; i++) {
      if (_parameterOids![i] != oids[i]) return false;
    }
    return true;
  }

  void abortPrepare() {
    assert(state == PreparedState.beingPrepared);
    manager.bySql.remove(sql);

    if (!isExplicit && autoPreparedSlotIndex >= 0) {
      manager.autoPrepared[autoPreparedSlotIndex] = statementBeingReplaced;
      if (statementBeingReplaced != null) {
        statementBeingReplaced!.state = PreparedState.prepared;
        statementBeingReplaced!.autoPreparedSlotIndex = autoPreparedSlotIndex;
      }
      autoPreparedSlotIndex = -1;
    }

    state = PreparedState.unprepared;
  }

  void completeUnprepare() {
    manager.bySql.remove(sql);
    manager.numPrepared--;
    state = PreparedState.unprepared;
  }

  @override
  String toString() => sql;

  /// Factory for explicit prepared statements.
  static PreparedStatement createExplicit({
    required PreparedStatementManager manager,
    required String sql,
    required String name,
    required List<int> parameterOids,
    PreparedStatement? statementBeingReplaced,
  }) {
    final ps = PreparedStatement(
      manager: manager,
      sql: sql,
      isExplicit: true,
    );
    ps.name = name;
    ps.statementBeingReplaced = statementBeingReplaced;
    ps.setParamTypes(parameterOids);
    return ps;
  }

  /// Factory for auto-prepare candidates.
  static PreparedStatement createAutoPrepareCandidate({
    required PreparedStatementManager manager,
    required String sql,
  }) {
    return PreparedStatement(
      manager: manager,
      sql: sql,
      isExplicit: false,
    );
  }
}

/// Manages prepared statements for a connection.
/// Porting PreparedStatementManager.cs
class PreparedStatementManager {
  PreparedStatementManager({
    this.maxAutoPrepared = 256,
    this.usagesBeforeAutoPrepare = 5,
  });

  final int maxAutoPrepared;
  final int usagesBeforeAutoPrepare;

  /// Prepared statements indexed by SQL.
  final Map<String, PreparedStatement> bySql = {};

  /// Auto-prepared statements (LRU cache).
  final List<PreparedStatement?> autoPrepared = [];

  /// Prepared statements evicted locally and waiting for Close on the backend.
  final List<PreparedStatement> _pendingUnprepare = [];

  int numPrepared = 0;
  int _nextPreparedStatementIndex = 0;

  String _generateStatementName() {
    return '_p${_nextPreparedStatementIndex++}';
  }

  /// Try to get an existing prepared statement by SQL.
  PreparedStatement? tryGetPreparedStatement(
      String sql, List<int> parameterOids) {
    final existing = bySql[sql];
    if (existing != null &&
        existing.isPrepared &&
        existing.doParametersMatch(parameterOids)) {
      existing.refreshLastUsed();
      existing.usages++;
      _recordHit();
      return existing;
    }
    _recordMiss();
    return null;
  }

  /// Create or get a prepared statement for explicit preparation.
  PreparedStatement getOrAddExplicit(String sql, List<int> parameterOids) {
    final existing = bySql[sql];
    if (existing != null) {
      existing.refreshLastUsed();
      existing.usages++;
      return existing;
    }

    final name = _generateStatementName();
    final ps = PreparedStatement.createExplicit(
      manager: this,
      sql: sql,
      name: name,
      parameterOids: parameterOids,
    );

    bySql[sql] = ps;
    numPrepared++;
    return ps;
  }

  /// Create or increment usage for auto-prepare candidate.
  PreparedStatement? tryGetOrCreateAutoPrepareCandidate(
      String sql, List<int> parameterOids) {
    final existing = bySql[sql];
    if (existing != null) {
      existing.refreshLastUsed();
      existing.usages++;

      if (!existing.doParametersMatch(parameterOids)) {
        if (existing.isExplicit) {
          return null;
        }
        bySql.remove(sql);
        if (!existing.isExplicit && existing.autoPreparedSlotIndex >= 0) {
          autoPrepared[existing.autoPreparedSlotIndex] = null;
          existing.autoPreparedSlotIndex = -1;
        }
        if (existing.isPrepared) {
          numPrepared--;
          existing.state = PreparedState.beingUnprepared;
          _pendingUnprepare.add(existing);
        } else {
          existing.state = PreparedState.unprepared;
        }
      } else {
        // Check if ready to promote to prepared
        if (!existing.isPrepared &&
            existing.state == PreparedState.notPrepared &&
            existing.usages >= usagesBeforeAutoPrepare) {
          // Ready to prepare
          return existing;
        }

        if (existing.isPrepared) {
          _recordHit();
          return existing;
        }
        return null;
      }
    }

    // Create new candidate
    _recordMiss();
    final ps = PreparedStatement.createAutoPrepareCandidate(
      manager: this,
      sql: sql,
    );
    ps.setParamTypes(parameterOids);
    ps.usages = 1;
    ps.refreshLastUsed();

    bySql[sql] = ps;
    if (ps.usages >= usagesBeforeAutoPrepare) {
      return ps;
    }
    return null; // Not ready for preparation yet
  }

  /// Clear all prepared statements.
  void clear() {
    bySql.clear();
    autoPrepared.clear();
    _pendingUnprepare.clear();
    numPrepared = 0;
  }

  /// Marks an auto-prepare candidate as being prepared and assigns a stable
  /// server-side statement name.
  PreparedStatement? beginAutoPrepare(
      PreparedStatement candidate, List<int> parameterOids) {
    if (maxAutoPrepared <= 0) {
      return null;
    }

    if (!identical(bySql[candidate.sql], candidate)) {
      bySql[candidate.sql] = candidate;
    }

    if (!_ensureAutoPreparedSlotCapacity(candidate)) {
      return null;
    }
    candidate.name ??= _generateStatementName();
    candidate.setParamTypes(parameterOids);
    candidate.state = PreparedState.beingPrepared;
    candidate.refreshLastUsed();
    return candidate;
  }

  /// Completes an automatic prepare operation after the backend has accepted
  /// the Parse/Bind flow.
  void completeAutoPrepare(PreparedStatement statement) {
    if (statement.state == PreparedState.prepared) {
      return;
    }
    statement.state = PreparedState.prepared;
    statement.refreshLastUsed();
    numPrepared++;
  }

  /// Takes auto-prepared statements that were evicted and still need to be
  /// closed on the backend connection.
  List<PreparedStatement> takePendingUnprepare() {
    if (_pendingUnprepare.isEmpty) {
      return const [];
    }
    final pending = List<PreparedStatement>.of(_pendingUnprepare);
    _pendingUnprepare.clear();
    return pending;
  }

  // Cache Metrics

  int _cacheHits = 0;
  int _cacheMisses = 0;

  /// Number of cache hits (statement found and reused).
  int get cacheHits => _cacheHits;

  /// Number of cache misses (statement not found).
  int get cacheMisses => _cacheMisses;

  /// Hit rate (percentage of requests that hit the cache).
  double get hitRate {
    final total = _cacheHits + _cacheMisses;
    return total == 0 ? 0.0 : _cacheHits / total;
  }

  /// Record a cache hit.
  void _recordHit() => _cacheHits++;

  /// Record a cache miss.
  void _recordMiss() => _cacheMisses++;

  /// Reset metrics.
  void resetMetrics() {
    _cacheHits = 0;
    _cacheMisses = 0;
  }

  /// Evict least recently used auto-prepared statement.
  /// Returns the evicted statement or null if nothing to evict.
  PreparedStatement? evictLRU() {
    if (autoPrepared.isEmpty) return null;

    // Find LRU statement
    PreparedStatement? lruStatement;
    int lruIndex = -1;
    var oldestTime = 0x7FFFFFFFFFFFFFFF;

    for (var i = 0; i < autoPrepared.length; i++) {
      final stmt = autoPrepared[i];
      if (stmt != null && !stmt.isExplicit && stmt.lastUsed <= oldestTime) {
        oldestTime = stmt.lastUsed;
        lruStatement = stmt;
        lruIndex = i;
      }
    }

    if (lruStatement != null && lruIndex >= 0) {
      // Remove from autoPrepared list
      autoPrepared[lruIndex] = null;
      lruStatement.autoPreparedSlotIndex = -1;

      // Remove from bySql map
      bySql.remove(lruStatement.sql);

      // Decrement counter
      if (lruStatement.isPrepared) {
        numPrepared--;
        lruStatement.state = PreparedState.beingUnprepared;
        _pendingUnprepare.add(lruStatement);
      } else {
        lruStatement.state = PreparedState.unprepared;
      }

      return lruStatement;
    }

    return null;
  }

  /// Evict multiple LRU statements.
  /// Returns list of evicted statements.
  List<PreparedStatement> evictLRUMultiple(int count) {
    final evicted = <PreparedStatement>[];

    for (var i = 0; i < count; i++) {
      final stmt = evictLRU();
      if (stmt == null) break;
      evicted.add(stmt);
    }

    return evicted;
  }

  /// Check if cache is full and evict if necessary.
  /// Called before adding new auto-prepared statement.
  void ensureCapacity() {
    if (numPrepared >= maxAutoPrepared) {
      // Evict 10% of cache to make room
      final toEvict = (maxAutoPrepared * 0.1).ceil();
      evictLRUMultiple(toEvict);
    }
  }

  bool _ensureAutoPreparedSlotCapacity(PreparedStatement candidate) {
    if (candidate.autoPreparedSlotIndex >= 0) {
      return true;
    }

    for (var i = 0; i < autoPrepared.length; i++) {
      if (autoPrepared[i] == null) {
        autoPrepared[i] = candidate;
        candidate.autoPreparedSlotIndex = i;
        return true;
      }
    }

    if (autoPrepared.length < maxAutoPrepared) {
      candidate.autoPreparedSlotIndex = autoPrepared.length;
      autoPrepared.add(candidate);
      return true;
    }

    final evicted = evictLRU();
    if (evicted != null) {
      final slot = autoPrepared.indexOf(null);
      if (slot < 0) {
        return false;
      }
      candidate.autoPreparedSlotIndex = slot;
      autoPrepared[slot] = candidate;
      return true;
    }

    return false;
  }

  /// Get current cache size percentage.
  double get cacheUsagePercent {
    if (maxAutoPrepared == 0) return 0.0;
    return (numPrepared / maxAutoPrepared) * 100;
  }
}
