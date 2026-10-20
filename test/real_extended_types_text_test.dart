// `Decode Extended Types As Text`: types without a natural Dart type come
// back as the server's text on every path (one-shot in text, prepared in
// binary), arrays as lists of texts, and money as the decimal amount.

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

const _scalars = [
  "'10:20:30.5'::time",
  "'24:00:00'::time",
  "'10:20:30+03'::timetz",
  "'10:20:30-05:30'::timetz",
  "'1 day 02:03:04'::interval",
  "'1 year 2 mons'::interval",
  "'-1 days +02:00:00'::interval",
  "'-3 hours -4 minutes'::interval",
  "'0'::interval",
  "'10.0.0.1'::inet",
  "'10.0.0.0/8'::cidr",
  "'::ffff:1.2.3.4'::inet",
  "'2001:db8::1/64'::inet",
  "'08:00:2b:01:02:03'::macaddr",
  "'(1,2)'::point",
  "'[(1,2),(3,4)]'::lseg",
  "'(3,4),(1,2)'::box",
  "'{1,2,3}'::line",
  "'[(1,2),(3,4)]'::path",
  "'((0,0),(1,0),(1,1))'::polygon",
  "'<(1,2),3>'::circle",
  "B'101'",
  "'a b'::tsvector",
  "'[1,5)'::int4range",
  "'empty'::int4range",
  "'[1.5,2.25]'::numrange",
  "'[2024-01-01,2024-02-01)'::daterange",
  "'[2024-01-01 10:00,2024-01-02 00:00:00.5)'::tsrange",
];

const _arrays = [
  "array['1 day'::interval, null, '1 year']",
  "array['10.0.0.1'::inet]",
  "array['[1,5)'::int4range]",
  "array['(1,2)'::point]",
];

DpgsqlParameterCollection _one() =>
    DpgsqlParameterCollection()..add(DpgsqlParameter('p0', 1));

Future<List<Object?>> _readEverywhere(DpgsqlConnection conn, String sql) async {
  final read = <Object?>[];
  for (var run = 0; run < 3; run++) {
    read
      ..add((await conn.executeMaps(sql)).single.values.single)
      ..add(await conn.executeScalar(sql))
      ..add(
          (await conn.executeMaps('$sql where ?::int = 1', parameters: _one()))
              .single
              .values
              .single);
  }
  return read;
}

void main() {
  late DpgsqlConnection conn;
  late DpgsqlConnection plain;
  var available = true;

  setUpAll(() async {
    final opened = await openRealConnectionOrSkip(
        options: 'Decode Extended Types As Text=true;'
            'Use Extended Query For Unparameterized Commands=true;'
            'Max Auto Prepare=32;Auto Prepare Min Usages=2');
    if (opened == null) {
      available = false;
      return;
    }
    conn = opened;
    plain = (await openRealConnectionOrSkip())!;
  });
  tearDownAll(() async {
    if (!available) return;
    await conn.close();
    await plain.close();
  });

  test('scalars are the server text on every path', () async {
    if (!available) return;
    for (final expr in _scalars) {
      // The type's output (rawText); `::text` differs for inet (`/32`).
      final expected = (await plain.executeMaps('select $expr as v',
              resultMode: PgResultMode.rawText))
          .single['v'];
      expect(await _readEverywhere(conn, 'select $expr as v'),
          everyElement(expected),
          reason: expr);
    }
  });

  test('arrays are lists of the elements text', () async {
    if (!available) return;
    for (final expr in _arrays) {
      final expected = [
        for (final row in await plain.executeMaps(
            'select e from unnest($expr) with ordinality u(e, n) order by n',
            resultMode: PgResultMode.rawText))
          row['e'],
      ];
      expect(await _readEverywhere(conn, 'select $expr as v'),
          everyElement(expected),
          reason: expr);
    }
  });

  test('money is the decimal amount, in text and in binary', () async {
    if (!available) return;
    for (final (expr, amount) in [
      ('12.34::money', '12.34'),
      ('(-0.05)::money', '-0.05'),
      ('1234567.89::money', '1234567.89'),
      ('0::money', '0.00'),
    ]) {
      expect(await _readEverywhere(conn, 'select $expr as v'),
          everyElement(amount),
          reason: expr);
    }
    // numeric casts: the money input parser follows lc_monetary.
    expect(
        await _readEverywhere(
            conn, 'select array[1.5::numeric::money, 2::money] as v'),
        everyElement(['1.50', '2.00']));
  });

  test('without the option the driver types are kept', () async {
    if (!available) return;
    expect(await plain.executeScalar("select '1 day'::interval"),
        isA<DpgsqlInterval>());
  });
}
