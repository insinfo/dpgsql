// ignore_for_file: always_use_package_imports

import '../timezone.dart';

import '../../../timezone_database_scope.dart';
import 'pg_timezone_data_10y.dart' as latest_10y;
import 'pg_timezone_data_all.dart' as latest_all;

/// PgLocationDatabase provides interface to find [Location]s by their name.
///
///     List<int> data = load(); // load database
///
///     PgLocationDatabase db = PgLocationDatabase.fromBytes(data);
///     Location loc = db.get('US/Eastern');
///
class PgLocationDatabase {
  PgLocationDatabase([this.scope = PgTimeZoneDatabaseScope.latestAll]);

  PgTimeZoneDatabaseScope scope;

  /// Mapping between [Location] name and [Location].
  Map<String, Location> get locations {
    return switch (scope) {
      PgTimeZoneDatabaseScope.latestAll => latest_all.pgDatabaseMap,
      PgTimeZoneDatabaseScope.latest10y => latest_10y.pgDatabaseMap,
    };
  }

  /// Adds [Location] to the database.
  void add(Location location) {
    locations[location.name] = location;
  }

  /// Finds [Location] by its name.
  Location get(String name) {
    if (!isInitialized) {
      // Before you can get a location, you need to manually initialize the
      // timezone location database by calling initializeDatabase or similar.
      throw LocationNotFoundException(
          'Tried to get location before initializing timezone database');
    }

    final loc = locations[name];
    if (loc == null) {
      throw LocationNotFoundException(
          'Location with the name "$name" doesn\'t exist');
    }
    return loc;
  }

  /// Clears the database of all [Location] entries.
  void clear() => locations.clear();

  /// Returns whether the database is empty, or has [Location] entries.
  bool get isInitialized => locations.isNotEmpty;
}

final _database = PgLocationDatabase();

/// Global TimeZone database
PgLocationDatabase get timeZoneDatabase => _database;

/// Find [Location] by its name.
///
/// ```dart
/// final detroit = getLocation('America/Detroit');
/// ```
void setTimeZoneDatabaseScope(PgTimeZoneDatabaseScope scope) {
  timeZoneDatabase.scope = scope;
}

/// Find [Location] by its name.
///
/// ```dart
/// final detroit = getLocation('America/Detroit');
/// ```
Location getLocation(
  String pgTimeZone, {
  PgTimeZoneDatabaseScope scope = PgTimeZoneDatabaseScope.latestAll,
}) {
  setTimeZoneDatabaseScope(scope);
  final tzLocations = timeZoneDatabase.locations.entries
      .where((e) {
        return e.key.toLowerCase() == pgTimeZone ||
            e.value.currentTimeZone.abbreviation.toLowerCase() == pgTimeZone;
      })
      .map((e) => e.value)
      .toList();

  if (tzLocations.isEmpty) {
    throw LocationNotFoundException(
        'Location with the name "$pgTimeZone" doesn\'t exist');
  }
  final tzLocation = tzLocations.first;
  return tzLocation;
}
