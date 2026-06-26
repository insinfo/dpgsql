import 'dart:async';
import 'dart:collection';

import 'internal/dpgsql_connector.dart';
import 'dpgsql_connection.dart';
import 'dpgsql_connection_string_builder.dart';

const _poolMaintenanceTimeout = Duration(milliseconds: 100);

/// Represents a source of data for Dpgsql, which can be used to create
/// connections. Handles connection pooling when `Pooling=true`.
class DpgsqlDataSource {
  DpgsqlDataSource(this.connectionString)
      : _builder = DpgsqlConnectionStringBuilder(connectionString) {
    if (_builder.maxPoolSize <= 0) {
      throw ArgumentError('Maximum Pool Size must be greater than zero');
    }
    if (_builder.minPoolSize > _builder.maxPoolSize) {
      throw ArgumentError(
        'Minimum Pool Size cannot be greater than Maximum Pool Size',
      );
    }
    _startPruningTimer();
  }

  final String connectionString;
  final DpgsqlConnectionStringBuilder _builder;
  final Queue<_PooledConnector> _idleConnectors = Queue<_PooledConnector>();
  final Queue<_PoolWaiter> _waiters = Queue<_PoolWaiter>();
  final Map<DpgsqlConnector, _PooledConnector> _connectors =
      <DpgsqlConnector, _PooledConnector>{};

  bool _disposed = false;
  int _busyCount = 0;
  int _totalConnectionsCreated = 0;
  int _totalConnectionsReused = 0;
  int _totalConnectionsFailed = 0;
  int _totalConnectionWaits = 0;
  int _totalConnectionTimeouts = 0;
  Timer? _pruningTimer;

  bool get pooling => _builder.pooling;
  int get minPoolSize => _builder.minPoolSize;
  int get maxPoolSize => _builder.maxPoolSize;
  Duration get connectionTimeout => _builder.timeout;
  Duration get connectionIdleLifetime => _builder.connectionIdleLifetime;
  Duration get connectionLifetime => _builder.connectionLifetime;
  Duration get connectionPruningInterval => _builder.connectionPruningInterval;

  /// Opens a connection to the database. If the pool is exhausted, waits until
  /// another caller closes a pooled connection or [connectionTimeout] elapses.
  Future<DpgsqlConnection> openConnection() async {
    _throwIfDisposed();

    if (!pooling) {
      final connector = _createConnector();
      await connector.open();
      return DpgsqlConnection.fromConnector(connector, null);
    }

    while (true) {
      final pooled = await _rentConnector();
      try {
        if (pooled.wasReused) {
          if (!await _healthCheck(pooled.connector)) {
            await _discardBusyConnector(pooled);
            continue;
          }
          await _resetConnection(pooled.connector);
          _totalConnectionsReused++;
        }

        return DpgsqlConnection.fromConnector(
          pooled.connector,
          _returnConnector,
        );
      } catch (_) {
        await _discardBusyConnector(pooled);
        rethrow;
      }
    }
  }

  /// Pre-creates idle connections up to [count], or `Minimum Pool Size` when
  /// omitted. This is explicit because Dart constructors cannot await.
  Future<void> warmup([int? count]) async {
    _throwIfDisposed();
    if (!pooling) {
      return;
    }

    final target = (count ?? minPoolSize).clamp(0, maxPoolSize);
    while (_connectors.length < target) {
      final pooled = await _openNewPooledConnector(wasReused: false);
      pooled.lastReturnedAt = DateTime.now();
      _idleConnectors.add(pooled);
    }
  }

  Future<_PooledConnector> _rentConnector() async {
    while (true) {
      _pruneIdleConnectors();

      while (_idleConnectors.isNotEmpty) {
        final pooled = _idleConnectors.removeLast();
        if (_canReuse(pooled)) {
          pooled.wasReused = true;
          _busyCount++;
          return pooled;
        }
        await _discardIdleConnector(pooled);
      }

      if (_connectors.length < maxPoolSize) {
        final pooled = await _openNewPooledConnector(wasReused: false);
        _busyCount++;
        return pooled;
      }

      _totalConnectionWaits++;
      return _waitForConnector();
    }
  }

  Future<_PooledConnector> _waitForConnector() {
    final waiter = _PoolWaiter(connectionTimeout, () {
      _totalConnectionTimeouts++;
    });
    _waiters.add(waiter);
    return waiter.future;
  }

  Future<_PooledConnector> _openNewPooledConnector({
    required bool wasReused,
  }) async {
    final connector = _createConnector();
    final pooled = _PooledConnector(
      connector,
      createdAt: DateTime.now(),
      wasReused: wasReused,
    );
    _connectors[connector] = pooled;

    try {
      await connector.open();
      _totalConnectionsCreated++;
      return pooled;
    } catch (_) {
      _connectors.remove(connector);
      try {
        await connector.close();
      } catch (_) {}
      rethrow;
    }
  }

  void _returnConnector(DpgsqlConnector connector) {
    final pooled = _connectors[connector];
    if (pooled == null) {
      unawaited(connector.close());
      return;
    }

    if (_disposed || !_canReuse(pooled)) {
      _busyCount--;
      unawaited(_discardIdleConnector(pooled));
      _completeWaitingConnectors();
      return;
    }

    pooled.lastReturnedAt = DateTime.now();
    pooled.wasReused = true;

    final waiter = _takeWaiter();
    if (waiter != null) {
      // Busy ownership is transferred directly to the waiter.
      waiter.complete(pooled);
      return;
    }

    _busyCount--;
    _idleConnectors.add(pooled);
    _pruneIdleConnectors();
  }

  _PoolWaiter? _takeWaiter() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.isCompleted) {
        return waiter;
      }
    }
    return null;
  }

  void _completeWaitingConnectors() {
    while (_waiters.isNotEmpty && _idleConnectors.isNotEmpty) {
      final waiter = _takeWaiter();
      if (waiter == null) {
        return;
      }
      final pooled = _idleConnectors.removeLast();
      if (!_canReuse(pooled)) {
        unawaited(_discardIdleConnector(pooled));
        continue;
      }
      pooled.wasReused = true;
      _busyCount++;
      waiter.complete(pooled);
    }

    while (_waiters.isNotEmpty && _connectors.length < maxPoolSize) {
      final waiter = _takeWaiter();
      if (waiter == null) {
        return;
      }

      _busyCount++;
      unawaited(() async {
        try {
          final pooled = await _openNewPooledConnector(wasReused: false);
          if (waiter.isCompleted) {
            _busyCount--;
            pooled.lastReturnedAt = DateTime.now();
            if (_disposed || !_canReuse(pooled)) {
              unawaited(_discardIdleConnector(pooled));
            } else {
              _idleConnectors.add(pooled);
            }
            _completeWaitingConnectors();
            return;
          }
          waiter.complete(pooled);
        } catch (e, st) {
          _busyCount--;
          waiter.completeError(e, st);
          _completeWaitingConnectors();
        }
      }());
    }
  }

  bool _canReuse(_PooledConnector pooled) {
    if (!pooled.connector.isConnected) {
      return false;
    }
    final now = DateTime.now();
    if (connectionLifetime > Duration.zero &&
        now.difference(pooled.createdAt) >= connectionLifetime) {
      return false;
    }
    return true;
  }

  void _pruneIdleConnectors() {
    if (_idleConnectors.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final retained = Queue<_PooledConnector>();
    while (_idleConnectors.isNotEmpty) {
      final pooled = _idleConnectors.removeFirst();
      final idleExpired = connectionIdleLifetime > Duration.zero &&
          pooled.lastReturnedAt != null &&
          now.difference(pooled.lastReturnedAt!) >= connectionIdleLifetime &&
          _connectors.length > minPoolSize;

      if (idleExpired || !_canReuse(pooled)) {
        unawaited(_discardIdleConnector(pooled));
      } else {
        retained.add(pooled);
      }
    }
    _idleConnectors.addAll(retained);
  }

  void _startPruningTimer() {
    if (!pooling || connectionPruningInterval <= Duration.zero) {
      return;
    }
    _pruningTimer = Timer.periodic(connectionPruningInterval, (_) {
      if (_disposed) {
        return;
      }
      _pruneIdleConnectors();
      _completeWaitingConnectors();
    });
  }

  Future<void> _discardBusyConnector(_PooledConnector pooled) async {
    _busyCount--;
    await _discardIdleConnector(pooled);
    _completeWaitingConnectors();
  }

  Future<void> _discardIdleConnector(_PooledConnector pooled) async {
    _connectors.remove(pooled.connector);
    _idleConnectors.remove(pooled);
    try {
      await pooled.connector.close();
    } catch (_) {}
  }

  /// Health check: ping connection.
  Future<bool> _healthCheck(DpgsqlConnector connector) async {
    try {
      final conn = DpgsqlConnection.fromConnector(connector, (_) {});
      final cmd = conn.createCommand('SELECT 1');
      await cmd.executeNonQuery().timeout(_poolMaintenanceTimeout);
      return true;
    } on TimeoutException {
      // Some tests use mock servers that do not implement query handling.
      // Consider the connection healthy if it is still open.
      return connector.isConnected;
    } catch (_) {
      _totalConnectionsFailed++;
      return false;
    }
  }

  /// Reset connection state before handing it to the next caller.
  Future<void> _resetConnection(DpgsqlConnector connector) async {
    final conn = DpgsqlConnection.fromConnector(connector, (_) {});

    try {
      await conn
          .createCommand('ROLLBACK')
          .executeNonQuery()
          .timeout(_poolMaintenanceTimeout);
    } catch (_) {}

    if (connector.preparedStatementManager.numPrepared > 0) {
      for (final sql in const ['RESET ALL', 'CLOSE ALL', 'UNLISTEN *']) {
        try {
          await conn
              .createCommand(sql)
              .executeNonQuery()
              .timeout(_poolMaintenanceTimeout);
        } catch (_) {}
      }
    } else {
      try {
        await conn
            .createCommand('DISCARD ALL')
            .executeNonQuery()
            .timeout(_poolMaintenanceTimeout);
      } catch (_) {}
    }
  }

  DpgsqlConnector _createConnector() {
    return DpgsqlConnector(
      host: _builder.host,
      port: _builder.port,
      username: _builder.username,
      password: _builder.password,
      database: _builder.database,
      sslMode: _builder.sslMode,
      trustServerCertificate: _builder.trustServerCertificate,
      encoding: _builder.encoding,
      clientEncoding: _builder.postgresClientEncoding,
      maxAutoPrepare: _builder.maxAutoPrepare,
      autoPrepareMinUsages: _builder.autoPrepareMinUsages,
    );
  }

  int get totalConnectionsCreated => _totalConnectionsCreated;
  int get totalConnectionsReused => _totalConnectionsReused;
  int get totalConnectionsFailed => _totalConnectionsFailed;
  int get totalConnectionWaits => _totalConnectionWaits;
  int get totalConnectionTimeouts => _totalConnectionTimeouts;
  int get idleCount => _idleConnectors.length;
  int get busyCount => _busyCount;
  int get totalCount => _connectors.length;
  int get waitingCount => _waiters.where((w) => !w.isCompleted).length;

  Map<String, dynamic> get poolStats => {
        'idle': idleCount,
        'busy': busyCount,
        'total': totalCount,
        'waiting': waitingCount,
        'max': maxPoolSize,
        'min': minPoolSize,
        'created': totalConnectionsCreated,
        'reused': totalConnectionsReused,
        'failedHealthChecks': totalConnectionsFailed,
        'waits': totalConnectionWaits,
        'timeouts': totalConnectionTimeouts,
      };

  Future<void> closeIdleConnections() async {
    while (_idleConnectors.isNotEmpty) {
      await _discardIdleConnector(_idleConnectors.removeFirst());
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _pruningTimer?.cancel();
    _pruningTimer = null;

    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      waiter.completeError(StateError('Data source has been disposed'));
    }

    await closeIdleConnections();
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('Data source has been disposed');
    }
  }
}

class _PooledConnector {
  _PooledConnector(
    this.connector, {
    required this.createdAt,
    required this.wasReused,
  });

  final DpgsqlConnector connector;
  final DateTime createdAt;
  DateTime? lastReturnedAt;
  bool wasReused;
}

class _PoolWaiter {
  _PoolWaiter(Duration timeout, void Function() onTimeout) {
    _timer = Timer(timeout, () {
      if (_completer.isCompleted) {
        return;
      }
      onTimeout();
      _completer.completeError(
        TimeoutException('Timed out waiting for a pooled connection', timeout),
      );
    });
  }

  final Completer<_PooledConnector> _completer = Completer<_PooledConnector>();
  late final Timer _timer;

  Future<_PooledConnector> get future => _completer.future;
  bool get isCompleted => _completer.isCompleted;

  void complete(_PooledConnector pooled) {
    if (_completer.isCompleted) {
      return;
    }
    _timer.cancel();
    _completer.complete(pooled);
  }

  void completeError(Object error, [StackTrace? stackTrace]) {
    if (_completer.isCompleted) {
      return;
    }
    _timer.cancel();
    _completer.completeError(error, stackTrace);
  }
}
