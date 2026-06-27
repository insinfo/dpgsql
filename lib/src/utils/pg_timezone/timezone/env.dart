import 'location.dart';
import 'location_database.dart';
import 'tzdb.dart';

/// Legacy placeholder from the upstream `timezone` API.
///
/// dpgsql does not load `latest.tzf` at runtime. PostgreSQL/IANA locations used
/// by the driver are generated as Dart code in `pg_timezone_data_all.dart` and
/// `pg_timezone_data_10y.dart` and are versioned with the package.
@Deprecated('dpgsql uses generated Dart timezone databases.')
const String tzDataDefaultFilename = 'pg_timezone_data_all.dart';

final _UTC = Location('UTC', [minTime], [0], [TimeZone.UTC]);

final _database = LocationDatabase();
Location _local = _UTC;

/// Global TimeZone database
LocationDatabase get timeZoneDatabase => _database;

/// UTC Location
Location get UTC => _UTC;

/// Local Location
///
/// By default it is instantiated with UTC [Location]
Location get local => _local;

/// Find [Location] by its name.
///
/// ```dart
/// final detroit = getLocation('America/Detroit');
/// ```
Location getLocation(String locationName) {
  return _database.get(locationName);
}

/// Set local [Location]
///
/// ```dart
/// final detroit = getLocation('America/Detroit')
/// setLocalLocation(detroit);
/// ```
void setLocalLocation(Location location) {
  _local = location;
}

/// Initialize Time zone database.
void initializeDatabase(List<int> rawData) async {
  _database.clear();
  //final file = File('timezones.txt');

  for (final l in tzdbDeserialize(rawData)) {
    // final name = l.name;
    // final transitionAt = l.transitionAt;
    // final transitionZone = l.transitionZone;
    // final zones = l.zones.map((z) => "TimeZone(${z.offset}, isDst: ${z.isDst}, abbreviation: '${z.abbreviation}')");
    // final contents = ''' '$name': Location('$name',[${transitionAt.join(',')}],[${transitionZone.join(',')}],[${zones.join(',')}]), ''';
    // await  file.writeAsString(contents,  mode: FileMode.append);
    _database.add(l);
  }

  _local = _UTC;
}
