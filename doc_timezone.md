Skip to content
Navigation Menu
isoos
postgresql-dart

Type / to search
Code
Issues
29
Pull requests
1
Discussions
Actions
Projects
Wiki
Security
Insights
value decoding (and encoding) needs additional access  #346
Open
@isoos
Description
isoos
opened on Aug 20, 2024
Owner
My hesitance to go ahead with #342 and also with #343 has the same root: in their current form, they seem to be adding non-trivial complexity that could become barriers for the future improvements, while in the ideal world such features should be added with much less friction and much less interconnectedness.

After a some thinking and high-level fiddling, I think I have found a way forward though: we will need to refactor the value encoding/decoding to have access to:

connection settings (like client-provided timezone)
runtime parameter values (like server-provided timezone)
the TypeRegistry itself (there should be no need to use any other reference than the one provided in the connection settings)
the connection or ways to open a new connection + an OID cache that can use it to query yet-unknown identifiers (this becomes tricky in certain clusters so it shouldn't be 100% automatic caching)
user-provided transformation functions for specific types - e.g. to pull in larger timezone databases like pg_timezone, which may not be needed for all users
I'm not entirely sure how such code would look like, but I think the above feature would now only allow the two pending features to go ahead, but also allow better overall extensibility.

/cc @insinfo @wolframm

Activity
isoos
isoos commented on Aug 20, 2024
isoos
on Aug 20, 2024
Owner
Author
I think the OID cache part has a clean separation from the rest. The other big change would be the decoding becoming async/FutureOr because of the potential need for OID type description query. It seems to be not breaking though.


isoos
mentioned this in 3 pull requests on Sep 2, 2024
TypeCodec #349
Customizable type registry. #353
Minimal RelationTracker (tracking RelationMessage) with further extensibility for oid caching. #354
isoos
isoos commented on Sep 5, 2024
isoos
on Sep 5, 2024
Owner
Author
I think this is now implemented, alongside with custom codec registration.

/cc @insinfo @wolframm: I've released a 3.4.0-dev.1 prerelease version with it, I think the API is good enough now, and you can go ahead with the PRs. Please let me know if there is something missing or in conflict with the goals.

isoos
isoos commented on Sep 13, 2024
isoos
on Sep 13, 2024
Owner
Author
Note: I've released 3.4.0-dev.2 with now with likely future-proofed async-enabled codec API (+ related message processing). Please, if possible, test and give me feedback before committing to a final version on it.

insinfo
insinfo commented on Sep 13, 2024
insinfo
on Sep 13, 2024
Hi, I had an accident and will be away from programming for a while. It would be great if you could implement timezone support based on my implementation with the modifications you introduced. Congratulations on your work.

isoos
isoos commented on Sep 17, 2024
isoos
on Sep 17, 2024
Owner
Author
@insinfo: I'm planning to help you out with the implementation, however I won't have the bandwidth for that in the next week or so. Because of that I've published 3.4.0 as-is, and we shall figure out the details for your use-case later, I'm rather optimistic that everything need is in it.

insinfo
Add a comment
new Comment
Markdown input: edit mode selected.
Write
Preview
Use Markdown to format your comment
Metadata
Assignees
No one assigned
Labels
No labels
Projects
No projects
Milestone
No milestone
Relationships
None yet
Development
No branches or pull requests
NotificationsCustomize
You're receiving notifications because you're subscribed to this thread.

Participants
@isoos
@insinfo
Issue actions
Footer
© 2025 GitHub, Inc.
Footer navigation
Terms
Privacy
Security
Status
Community
Docs
Contact
Manage cookies
Do not share my personal information
value decoding (and encoding) needs additional access · Issue #346 · isoos/postgresql-dart

Skip to content
Navigation Menu
isoos
postgresql-dart

Type / to search
Code
Issues
29
Pull requests
1
Discussions
Actions
Projects
Wiki
Security
Insights
Investigate: timestamp without timezone #339
Open
@isoos
Description
isoos
opened on May 18, 2024
Owner
It is not clear to me what should be the behavior when the server and the client have different timezones (both different than UTC). We should investigate and fix if needed.

Activity

isoos
mentioned this on May 18, 2024
Fixed double/real + added timestamp, numeric, date & json #338
hendrik-brower
hendrik-brower commented on Jun 1, 2024
hendrik-brower
on Jun 1, 2024
I was just experimenting with ConnectionSettings, setting timezone to 'UTC' and 'America/New_York', 'EST'. Then running connection.execute with a series of statements:
select curent_timestamp;
set timezone to 'UTC';
select curent_timestamp;
set timezone to 'America/New_York';
select curent_timestamp;
set timezone to 'EST';
select curent_timestamp;
All select statements return the same string (with trailing Z) that reflects the database's timezone (ie alter database x set timezone y). This differs from the behavior I observe when running the running same queries through the psql command line utility. When running through command line utility, I get time stamps with +00, -04, -05 (reflecting the connection setting).

From this, it seems like the ConnectionSettings timezone value is not applied. It also seems like the set timezone statements do not affect the connection. Maybe each query is running in a separate session?

I think this would not be much of an issue if when retrieving a value, eg: res[0][0] as DateTime, returned a DateTime object that was a utc value. And when passing one, it converted it to utc. But it seems to return it as a local datetime, so you end up with a timeshift on the client size. Presently, to make things work as expected, I need to "insert (ct) values (@ct)" with ct=DateTime.now().toUtc(). Then after reading it, convert it to utc to get a matching result.

I haven't experimented with doing this in a session obtained via connection.run, though I would think a "connection" represents a session where as run(fn(session)) would represent a separate session. A bit more documentation on the top level classes to help outline these sorts of details would be great.

hendrik-brower
hendrik-brower commented on Jun 1, 2024
hendrik-brower
on Jun 1, 2024
Just tried the same sequence with a session... same result. no returned values appear to respect the timezone set by "set timezone 'xx'" command. All values seem to be fixed to the database's setting.

isoos
isoos commented on Jun 2, 2024
isoos
on Jun 2, 2024
Owner
Author
@hendrik-brower: thank you for looking into this! Would you be also interested in writing a fix? I'd be happy to review and guide if needed.

hendrik-brower
hendrik-brower commented on Jun 3, 2024
hendrik-brower
on Jun 3, 2024 via email
I will have a bit of time in the second half of June.  I'll try to take a
look at it then.
…
insinfo
insinfo commented on Jul 9, 2024
insinfo
on Jul 9, 2024 · edited by insinfo
@isoos @hendrik-brower
Today I was facing a problem precisely because of this driver problem of placing "Z" in all timestamp type columns, from what I read, timestamp type columns without timezone should not place "Z" because timestamp columns by definition do not have time zone information and cannot be considered UTC, I believe that the ideal solution is to modify the implementation to something like:

 case PostgreSQLDataType.timestampWithoutTimezone:
        try {
          final value = buffer.getInt64(0);
          //final date = DateTime.utc(2000).add(Duration(microseconds: value));      
          final date = DateTime(2000).add(Duration(microseconds: value));
          return date as T;
        } catch (e) {
          return null;
        }
      case PostgreSQLDataType.timestampWithTimezone:
        try {
          final value = buffer.getInt64(0);          
          final date = DateTime.utc(2000).add(Duration(microseconds: value));
          return date as T;
        } catch (e) {
          return null;
        }
      case PostgreSQLDataType.date:
        try {
          final value = buffer.getInt32(0);
          // final date = DateTime.utc(2000).add(Duration(days: value));          
          final date = DateTime(2000).add(Duration(days: value));
          return date as T;
        } catch (e) {
          return null;
        }
so timestamp columns without timezone do not have the "Z", which will avoid problems comparing dates that come from the database with DateTime.now();

from what I saw the C# npgsql driver does not put timestamp columns Without Timezone as UTC

I think this must be the correct behavior for postgresql-dart as well.
https://www.npgsql.org/doc/types/datetime.html
this same code implemented in dart has different behavior

// CREATE TABLE "sigep"."inscricoes" (
 // "id" int4 NOT NULL DEFAULT nextval('"sigep".inscricoes_id_seq'::regclass),
 // "titulo" text COLLATE "pg_catalog"."default" NOT NULL,
 // "anoExercicio" int4 NOT NULL,
//  "dataInicial" timestamp(6) NOT NULL,
//  "dataFinal" timestamp(6) NOT NULL,
//  "dataZ" timestamptz(6),
//  CONSTRAINT "id_pkey" PRIMARY KEY ("id")
// );

using Npgsql;
using System;
using System.Data;

var connString = "Host=localhost;Username=dart;Password=dart;Port=5435;Database=sistemas";

var dataSourceBuilder = new NpgsqlDataSourceBuilder(connString);
var dataSource = dataSourceBuilder.Build();

var conn = await dataSource.OpenConnectionAsync();

//await using (var cnd1 = new NpgsqlCommand("INSERT INTO sigep.inscricoes (titulo,\"anoExercicio\",\"dataInicial\",\"dataFinal\",\"dataZ\") VALUES ('teste','2024','2024-07-10 17:10:00','2024-07-10 18:20:00','2024-07-10 15:35:23-03')", conn))
//{
   // cnd1.Parameters.AddWithValue("p", "Hello world");
    //await cnd1.ExecuteNonQueryAsync();
//}
await using (var cmd = new NpgsqlCommand("SELECT * FROM sigep.inscricoes WHERE  id=2", conn))

await using (var reader = await cmd.ExecuteReaderAsync())
{
    DateTime now = DateTime.Now;
    TimeZoneInfo localZone = TimeZoneInfo.Local;
    string standardName = localZone.StandardName;
    string daylightName = localZone.DaylightName;

    while (await reader.ReadAsync())
    {
        var dataInicial = reader.GetDateTime(3); 
        var dataFinal = reader.GetDateTime(4); 

        var dataZ = reader.GetDateTime(5);

        Console.WriteLine($"dataInicial {dataInicial.Kind == DateTimeKind.Utc} {dataInicial} {TimeZoneInfo.Local.GetUtcOffset(dataInicial)}");
        Console.WriteLine($"dataFinal {dataFinal.Kind == DateTimeKind.Utc} {dataFinal} {TimeZoneInfo.Local.GetUtcOffset(dataFinal)}");
        Console.WriteLine($"now {now.Kind == DateTimeKind.Utc} {now} {TimeZoneInfo.Local.GetUtcOffset(now)}");

        if(now >= dataInicial && now <= dataFinal)
        {
            Console.WriteLine("registration open");
        }
        else
        {
            Console.WriteLine("registration closed");
        }

        Console.WriteLine($"dataZ {dataZ.Kind == DateTimeKind.Utc} {dataZ} {TimeZoneInfo.Local.GetUtcOffset(dataZ)}");     

    }        
}

//dataInicial False 10/07/2024 17:10:00 -03:00:00
//dataFinal False 10/07/2024 18:20:00 -03:00:00
//now False 10/07/2024 16:51:14 -03:00:00
//registration closed
//dataZ True 10/07/2024 18:35:23 -03:00:00
I took a look at how I implemented this in the dargres driver and saw that it was like this

/// Decodes [value] into a [DateTime] instance.
  ///
  /// Note: it will convert it to local time (via [DateTime.toLocal])
  DateTime decodeDateTime(String value, int pgType) {
    // Built in Dart dates can either be local time or utc. Which means that the
    // the postgresql timezone parameter for the connection must be either set
    // to UTC, or the local time of the server on which the client is running.
    // This restriction could be relaxed by using a more advanced date library
    // capable of creating DateTimes for a non-local time zone.

    if (value == 'infinity' || value == '-infinity')
      throw _error('A timestamp value "$value", cannot be represented '
          'as a Dart object.');
    //if infinity values are required, rewrite the sql query to cast
    //the value to a string, i.e. your_column::text.

    var formattedValue = value;

    // Postgresql uses a BC suffix rather than a negative prefix as in ISO8601.
    if (value.endsWith(' BC'))
      formattedValue = '-' + value.substring(0, value.length - 3);

    if (pgType == TIMESTAMP) {
      formattedValue += 'Z';
    } else if (pgType == TIMESTAMPTZ) {
      // PG will return the timestamp in the connection's timezone. The resulting DateTime.parse will handle accordingly.
    } else if (pgType == DATE) {
      formattedValue = formattedValue + 'T00:00:00Z';
    }

    return DateTime.parse(formattedValue).toLocal();
  }
isoos
isoos commented on Jul 11, 2024
isoos
on Jul 11, 2024
Owner
Author
@insinfo: Thank you, that is great to see! I think this is a good starting material for a reduced test case + updated implementation. Would you be interested in preparing that too?

insinfo
insinfo commented on Jul 11, 2024
insinfo
on Jul 11, 2024
I don't know if I'll have time to do this this week because I'm very busy, but from what I've seen I think the hardest part will be making the PostgresBinaryDecoder class have access to the timestamp information that PostgreSQL sends when authenticating so that it can use this information when decoding a timestamp with timezone, I think there will have to be changes in several places so that PostgresBinaryDecoder has access to this information.

https://github.com/isoos/postgresql-dart/blob/917fd326dcd1c0c09e4de1842d8b5d9bc1b8e7fe/lib/src/types/binary_codec.dart

I wonder if @simolus3 @busslina can help with this

insinfo
insinfo commented on Jul 11, 2024
insinfo
on Jul 11, 2024 · edited by insinfo
both the java implementation and the C# implementation result in "registration open" but in dart it results in "registration closed"

dart implementation

import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:postgres/postgres.dart';

void main() async {
  await initializeDateFormatting('pt_BR');

  //Intl.systemLocale = await findSystemLocale();
  Intl.defaultLocale = 'pt_BR';

  print('Intl.defaultLocale  ${Intl.defaultLocale}');
  // Database connection
  final connection = await Connection.open(
      Endpoint(
          host: 'localhost',
          port: 5435,
          database: 'sistemas',
          username: 'dart',
          password: 'dart'),
      settings: ConnectionSettings(sslMode: SslMode.disable));

  // Current time and timezone info
  final now = DateTime.now();
  final dtInicio =
      now.subtract(Duration(minutes: 5)); 
  final dtFim = now.add(Duration(minutes: 120));
  final dt3 = DateTime(2024,07,11);
  print('now ${now.hour}h');
  final timezoneName = now.timeZoneName;
  print('Standard Timezone Name: $timezoneName');
  await connection.execute(
    Sql.indexed('''
INSERT INTO sigep.inscricoes (id, titulo, "anoExercicio", "dataInicial", "dataFinal", "dataZ", "data3")
  VALUES ('2', 'teste', '2024', '${dtInicio.toIso8601String()}', '${dtFim.toIso8601String()}',  '${now.toIso8601String()}',  '${dt3.toIso8601String()}')
ON CONFLICT (id)
DO UPDATE SET
   titulo = EXCLUDED.titulo,
  "anoExercicio" = EXCLUDED."anoExercicio",
  "dataInicial" = EXCLUDED."dataInicial",
  "dataFinal" = EXCLUDED."dataFinal",
  "dataZ" = EXCLUDED."dataZ",
  "data3" = EXCLUDED."data3"
WHERE
  sigep.inscricoes.id = '2' 
 '''),
  );

  final results = await connection.execute(
      Sql.indexed('SELECT * FROM sigep.inscricoes WHERE id = ? ',
          substitution: '?'),
      parameters: [2]);

  for (ResultRow item in results) {
    final row = item.toColumnMap();

    final dataInicial = row['dataInicial'] as DateTime;
    final dataFinal = row['dataFinal'] as DateTime;
    final dataZ = row['dataZ'] as DateTime;
    final data3 = row['data3'] as DateTime;

    print('dt3 == data3 ${dt3 == data3}');

    print(
        'dataInicial ${dataInicial.timeZoneOffset == Duration.zero ? 'UTC' : 'Local'} $dataInicial ${dataInicial.timeZoneOffset}');
    print(
        'dataFinal ${dataFinal.timeZoneOffset == Duration.zero ? 'UTC' : 'Local'} $dataFinal ${dataFinal.timeZoneOffset}');
    print(
        'now ${now.timeZoneOffset == Duration.zero ? 'UTC' : 'Local'} $now ${now.timeZoneOffset}');

    if (now.isAfter(dataInicial) && now.isBefore(dataFinal)) {
      print('registration open');
    } else {
      print('registration closed');
    }
    print(
      'dataZ ${dataZ.timeZoneOffset == Duration.zero ? 'UTC' : 'Local'} $dataZ ${dataZ.timeZoneOffset}',
    );
  }
  await connection.close();
}

// PS C:\MyDartProjects\new_sigep\backend> dart .\bin\teste_date.dart
// Intl.defaultLocale  pt_BR
// now 19h
// Standard Timezone Name: Hora oficial do Brasil
// dt3 == data3 false
// dataInicial UTC 2024-07-11 19:30:13.112467Z 0:00:00.000000
// dataFinal UTC 2024-07-11 21:35:13.112467Z 0:00:00.000000
// now Local 2024-07-11 19:35:13.112467 -3:00:00.000000
// registration closed
// dataZ UTC 2024-07-11 19:35:13.112467Z 0:00:00.000000
C# implementation

using Npgsql;
using System;
using System.Data;

var connString = "Host=localhost;Username=dart;Password=dart;Port=5435;Database=sistemas";

var dataSourceBuilder = new NpgsqlDataSourceBuilder(connString);
var dataSource = dataSourceBuilder.Build();

var conn = await dataSource.OpenConnectionAsync();

// Current time and timezone info
var now = DateTime.Now;
var dtInicio = now.AddMinutes(-5);
var dtFim = now.AddMinutes(120);
var dt3 = new DateTime(2024, 7, 11);

Console.WriteLine($"now {now.Hour}h");
TimeZoneInfo localZone = TimeZoneInfo.Local;
var timezoneName = localZone.StandardName;
Console.WriteLine($"Standard Timezone Name: {timezoneName}");

var upsertCommandText = $@"
            INSERT INTO sigep.inscricoes (id, titulo, ""anoExercicio"", ""dataInicial"", ""dataFinal"", ""dataZ"", ""data3"")
            VALUES ('2', 'teste', '2024', '{dtInicio:yyyy-MM-ddTHH:mm:ss}', '{dtFim:yyyy-MM-ddTHH:mm:ss}', '{now:yyyy-MM-ddTHH:mm:ss}', '{dt3:yyyy-MM-ddTHH:mm:ss}')
            ON CONFLICT (id)
            DO UPDATE SET                
               titulo = EXCLUDED.titulo,
              ""anoExercicio"" = EXCLUDED.""anoExercicio"",
              ""dataInicial"" = EXCLUDED.""dataInicial"",
              ""dataFinal"" = EXCLUDED.""dataFinal"",
              ""dataZ"" = EXCLUDED.""dataZ"",
              data3 = EXCLUDED.data3
        ";

using (var upsertCommand = new NpgsqlCommand(upsertCommandText, conn))
{
    await upsertCommand.ExecuteNonQueryAsync();
}

await using (var cmd = new NpgsqlCommand("SELECT * FROM sigep.inscricoes WHERE  id=2", conn))


await using (var reader = await cmd.ExecuteReaderAsync())
{
        
   
    while (await reader.ReadAsync())
    {
        var dataInicial = reader.GetDateTime(reader.GetOrdinal("dataInicial"));
        var dataFinal = reader.GetDateTime(reader.GetOrdinal("dataFinal")); 
        var dataZ = reader.GetDateTime(reader.GetOrdinal("dataZ"));
        var data3 = reader.GetDateTime(reader.GetOrdinal("data3"));
        Console.WriteLine($"dt3 == data3 {dt3 == data3}");
        Console.WriteLine($"dataInicial {(dataInicial.Kind == DateTimeKind.Utc ? "UTC" : "Local")} {dataInicial} {TimeZoneInfo.Local.GetUtcOffset(dataInicial)}");
        Console.WriteLine($"dataFinal {(dataFinal.Kind == DateTimeKind.Utc ? "UTC" : "Local")} {dataFinal} {TimeZoneInfo.Local.GetUtcOffset(dataFinal)}");
        Console.WriteLine($"now {(now.Kind == DateTimeKind.Utc ? "UTC" : "Local")} {now} {TimeZoneInfo.Local.GetUtcOffset(now)}");

        if(now >= dataInicial && now <= dataFinal)
        {
            Console.WriteLine("registration open");
        }
        else
        {
            Console.WriteLine("registration closed");
        }

        Console.WriteLine($"dataZ {(now.Kind == DateTimeKind.Utc ? "UTC" : "Local")} {dataZ} {TimeZoneInfo.Local.GetUtcOffset(dataZ)}");     

    }        
}
// now 19h
// Standard Timezone Name: Hora oficial do Brasil
// dt3 == data3 True
// dataInicial Local 11/07/2024 19:32:14 -03:00:00
// dataFinal Local 11/07/2024 21:37:14 -03:00:00
// now Local 11/07/2024 19:37:14 -03:00:00
// registration open
// dataZ Local 11/07/2024 22:37:14 -03:00:00
java implementation

package org.example;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;

public class Main {

    public static void main(String[] args) {
        String url = "jdbc:postgresql://localhost:5435/sistemas";
        String user = "dart";
        String password = "dart";

        try (Connection conn = DriverManager.getConnection(url, user, password)) {
            // Current time and timezone info
            LocalDateTime now = LocalDateTime.now();
            LocalDateTime dtInicio = now.minusMinutes(5);
            LocalDateTime dtFim = now.plusMinutes(120);
            LocalDate dt3 = LocalDate.of(2024, 7, 11);

            System.out.println("now " + now.getHour() + "h");
            ZoneId zoneId = ZoneId.systemDefault();
            String timezoneName = zoneId.getId();
            System.out.println("Standard Timezone Name: " + timezoneName);

            String upsertCommandText = String.format(
                    """
                    INSERT INTO sigep.inscricoes (id, titulo, "anoExercicio", "dataInicial", "dataFinal", "dataZ", "data3")
                    VALUES (2, 'teste', 2024, '%s', '%s', '%s', '%s')
                    ON CONFLICT (id)
                    DO UPDATE SET
                       titulo = EXCLUDED.titulo,
                       "anoExercicio" = EXCLUDED."anoExercicio",
                       "dataInicial" = EXCLUDED."dataInicial",
                       "dataFinal" = EXCLUDED."dataFinal",
                       "dataZ" = EXCLUDED."dataZ",
                       data3 = EXCLUDED.data3
                    """,
                    dtInicio.format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss")),
                    dtFim.format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss")),
                    now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss")),
                    dt3.format(DateTimeFormatter.ofPattern("yyyy-MM-dd"))
            );

            try (Statement upsertCommand = conn.createStatement()) {
                upsertCommand.executeUpdate(upsertCommandText);
            }

            String selectQuery = """
                SELECT * FROM sigep.inscricoes WHERE id=2
            """;

            try (PreparedStatement selectCommand = conn.prepareStatement(selectQuery);
                 ResultSet reader = selectCommand.executeQuery()) {

                while (reader.next()) {
                    LocalDateTime dataInicial = reader.getObject("dataInicial", LocalDateTime.class);
                    LocalDateTime dataFinal = reader.getObject("dataFinal", LocalDateTime.class);
                    OffsetDateTime dataZ = reader.getObject("dataZ", OffsetDateTime.class);
                    LocalDate data3 = reader.getObject("data3", LocalDate.class);

                    System.out.println("dt3 == data3 " + dt3.equals(data3));
                    System.out.println("dataInicial " + dataInicial + " " + zoneId.getRules().getOffset(dataInicial));
                    System.out.println("dataFinal " + dataFinal + " " + zoneId.getRules().getOffset(dataFinal));
                    System.out.println("now " + now + " " + zoneId.getRules().getOffset(now));

                    if (now.isAfter(dataInicial) && now.isBefore(dataFinal)) {
                        System.out.println("registration open");
                    } else {
                        System.out.println("registration closed");
                    }

                    System.out.println("dataZ " + dataZ + " " + dataZ.getOffset());
                }
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}

19:28:06: Executing ':Main.main()'...

now 19h
Standard Timezone Name: America/Sao_Paulo
dt3 == data3 true
dataInicial 2024-07-11T19:23:06 -03:00
dataFinal 2024-07-11T21:28:06 -03:00
now 2024-07-11T19:28:06.601428600 -03:00
registration open
dataZ 2024-07-11T22:28:06Z Z
19:28:06: Execution finished ':Main.main()'.

isoos
isoos commented on Jul 12, 2024
isoos
on Jul 12, 2024
Owner
Author
Note: I've added timeZone parameter to withPostgresServer test grouping method (not much but hoping to spend more time on it next week).

insinfo
insinfo commented on Jul 19, 2024
insinfo
on Jul 19, 2024 · edited by insinfo
@isoos @hendrik-brower @busslina

I implemented TimeZone support in BinaryDecoder, with this PR the behavior of timestamp decoding with timezone follows the timezone set for the connection using the command "set timezone to 'America/Sao_Paulo'" returning a DateTime with the due timezone similar to the behavior exhibited by psql, and the decoding of timestamp without timezone becomes a local DateTime

#342

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:postgres/postgres.dart';

void main(List<String> args) async {
  
  final connection = await Connection.open(
    Endpoint(
      host: 'localhost',
      port: 5435,
      database: 'sistemas',
      username: 'dart',
      password: 'dart',
    ),
    settings: ConnectionSettings(sslMode: SslMode.disable),
  );
// print('now:  ${DateTime.now()} ${DateTime.now().timeZoneName}');

  var results = await connection.execute("select current_timestamp");
  var currentTimestamp = results.first.first as DateTime;
  print('dafault: $currentTimestamp ${currentTimestamp.timeZoneName}');
  print('local: ${currentTimestamp.toLocal()}');

  await connection.execute("set timezone to 'America/Sao_Paulo'");
  results = await connection.execute("select current_timestamp");
  currentTimestamp = results.first.first as DateTime;
  print(
      'America/Sao_Paulo: $currentTimestamp ${currentTimestamp.timeZoneName}');

  await connection.execute("set timezone to 'UTC'");
  results = await connection.execute("select current_timestamp");
  currentTimestamp = results.first.first as DateTime;
  print('UTC: $currentTimestamp ${currentTimestamp.timeZoneName}');

  await connection.execute("set timezone to 'America/New_York'");
  results = await connection.execute("select current_timestamp");
  currentTimestamp = results.first.first as DateTime;
  print('America/New_York: $currentTimestamp ${currentTimestamp.timeZoneName}');

  await connection.execute("set timezone to 'EST'");
  results = await connection.execute("select current_timestamp");
  currentTimestamp = results.first.first as DateTime;
  print('EST: $currentTimestamp ${currentTimestamp.timeZoneName}');

  results = await connection.execute(
      "SELECT 'infinity'::TIMESTAMP as col1, '-infinity'::TIMESTAMP as col2, 'infinity'::date as col3, '-infinity'::date as col3");
  print('main: $results');

  await connection.execute("set timezone to 'America/Sao_Paulo'");
  await connection.execute(
      '''UPDATE "sigep"."inscricoes" SET "dataZ" = \$1 WHERE "id" = 2 ''',
      parameters: [DateTime.now()]);
  results = await connection
      .execute("SELECT \"dataZ\" FROM sigep.inscricoes WHERE id=2");
  print('main: $results');

  await connection.close();
}
dafault: 2024-07-19 21:12:43.832166Z UTC
local: 2024-07-19 18:12:43.832166
America/Sao_Paulo: 2024-07-19 18:12:43.857805-0300 -03
UTC: 2024-07-19 21:12:43.944204Z UTC
America/New_York: 2024-07-19 17:12:43.950071-0400 EDT
EST: 2024-07-19 16:12:43.956152-0500 EST
main: [[null, null, null, null]]
main: [[2024-07-19 18:12:43.965045-0300]]
leandroveronezi
leandroveronezi commented on Jan 30
leandroveronezi
on Jan 30
any update on the case?

insinfo
Add a comment
new Comment
Markdown input: edit mode selected.
Write
Preview
Use Markdown to format your comment
Metadata
Assignees
No one assigned
Labels
No labels
Projects
No projects
Milestone
No milestone
Relationships
None yet
Development
No branches or pull requests
NotificationsCustomize
You're receiving notifications because you're subscribed to this thread.

Participants
@isoos
@hendrik-brower
@insinfo
@leandroveronezi
Issue actions
Footer
© 2025 GitHub, Inc.
Footer navigation
Terms
Privacy
Security
Status
Community
Docs
Contact
Manage cookies
Do not share my personal information
Investigate: timestamp without timezone · Issue #339 · isoos/postgresql-dart

Skip to content
Navigation Menu
isoos
postgresql-dart

Type / to search
Code
Issues
29
Pull requests
1
Discussions
Actions
Projects
Wiki
Security
Insights
not working with iso_8859_1 data #25
Open
Open
not working with iso_8859_1 data
#25
@insinfo
Description
insinfo
opened on Jan 14, 2022
i'm accessing a database with data encoded in iso_8859_1 and i'm getting this error, i can access without problems with navicat

image

image

dart run .\example\main2.dart
Unhandled exception:
FormatException: Unexpected extension byte (at offset 1)
#0      _Utf8Decoder.convertSingle (dart:convert-patch/convert_patch.dart:1783:7)
#1      Utf8Decoder.convert (dart:convert/utf.dart:322:42)
#2      Utf8Codec.decode (dart:convert/utf.dart:63:20)
#3      PostgresBinaryDecoder.convert (package:postgres/src/binary_codec.dart:417:21)
#4      Query.addRow.<anonymous closure> (package:postgres/src/query.dart:148:41)
#5      MappedListIterable.elementAt (dart:_internal/iterable.dart:411:31)
#6      ListIterator.moveNext (dart:_internal/iterable.dart:340:26)
#7      new _GrowableList._ofEfficientLengthIterable (dart:core-patch/growable_array.dart:188:27)
#8      new _GrowableList.of (dart:core-patch/growable_array.dart:150:28)
#9      new List.of (dart:core-patch/array_patch.dart:50:28)
#10     ListIterable.toList (dart:_internal/iterable.dart:211:44)
#11     Query.addRow (package:postgres/src/query.dart:151:30)
#12     _PostgreSQLConnectionStateBusy.onMessage (package:postgres/src/connection_fsm.dart:297:13)
#13     PostgreSQLConnection._readData (package:postgres/src/connection.dart:286:47)
#14     _RootZone.runUnaryGuarded (dart:async/zone.dart:1546:10)
#15     _BufferingStreamSubscription._sendData (dart:async/stream_impl.dart:341:11)
#16     _BufferingStreamSubscription._add (dart:async/stream_impl.dart:271:7)
#17     _SyncStreamControllerDispatch._sendData (dart:async/stream_controller.dart:733:19)
#18     _StreamController._add (dart:async/stream_controller.dart:607:7)
#27     new _RawSocket.<anonymous closure> (dart:io-patch/socket_patch.dart:1680:33)
#28     _NativeSocket.issueReadEvent.issue (dart:io-patch/socket_patch.dart:1192:14)
#29     _microtaskLoop (dart:async/schedule_microtask.dart:40:21)
#30     _startMicrotaskLoop (dart:async/schedule_microtask.dart:49:5)
#31     _runPendingImmediateCallback (dart:isolate-patch/isolate_patch.dart:120:13)
#32     _RawReceivePortImpl._handleMessage (dart:isolate-patch/isolate_patch.dart:185:5)



import 'dart:io';
import 'package:postgres/postgres.dart';

void main(List<String> args) async {
  var connection = PostgreSQLConnection('192.168.66.5', 5432, 'sistemas',
      username: 'sisadmin', password: 's1sadm1n');
  await connection.open();
  var query = '''
    SELECT SUM
	( a1.nr_vaga - a1.nr_vagaefetiv ) AS qtd,
	a3.nm_cargo,
	a1.nm_exigencia 
FROM
	sibem.tb_emprcargo a1,
	sibem.tb_empregador a2,
	sibem.tb_cargo a3 
WHERE
	a1.dt_encerra ISNULL 
	AND ( a1.nr_vaga - a1.nr_vagaefetiv ) > 0 
	AND a1.cd_empregador = a2.cd_empregador 
	AND a1.cd_cargo = a3.cd_cargo 
GROUP BY
	a3.nm_cargo,
	a1.nm_exigencia 
ORDER BY
	a3.nm_cargo
    ''';
  List<List<dynamic>> results = await connection.query(query);

  for (final row in results) {
    print(row);
  }
  exit(0);
}
Activity
isoos
isoos commented on Jan 14, 2022
isoos
on Jan 14, 2022
Owner
The package assumes utf8 encoding everywhere, and while in theory we could make that configurable, I have no idea if it would solve your use case. If you wanted to, I can review PRs and give directions how to do it, but I likely won't have time to do it.

insinfo
insinfo commented on Jan 14, 2022
insinfo
on Jan 14, 2022
Author
the ideal is if I had something like this, to be able to say the charset of the database and the driver to do the conversion to utf8 automatically similar to php

pg_set_client_encoding(resource $connection = ?, string $encoding): int
https://www.php.net/manual/pt_BR/function.pg-set-client-encoding.php

isoos
isoos commented on Jan 14, 2022
isoos
on Jan 14, 2022
Owner
@insinfo: There may be some automatic thing we can do. After you open the connection, could you please print(connection.settings); and copy the output of that here? (if it is empty, please do a connection.query('SELECT 1'); first...)

insinfo
insinfo commented on Jan 17, 2022
insinfo
on Jan 17, 2022
Author
@isoos

print(connection.settings);

PS C:\MyDartProjects\fluent_query_builder> dart .\example\main2.dart
connection.settings: {client_encoding: UTF8, DateStyle: ISO, MDY, integer_datetimes: on, is_superuser: off, server_encoding: SQL_ASCII, server_version: 8.1.19, session_authorization: sisadmin, standard_conforming_strings: off, TimeZone: UTC}
Unhandled exception:
FormatException: Unexpected extension byte (at offset 1)
#0      _Utf8Decoder.convertSingle (dart:convert-patch/convert_patch.dart:1783:7)
#1      Utf8Decoder.convert (dart:convert/utf.dart:322:42)
#2      Utf8Codec.decode (dart:convert/utf.dart:63:20)
#3      PostgresBinaryDecoder.convert (package:postgres/src/binary_codec.dart:417:21)
#4      Query.addRow.<anonymous closure> (package:postgres/src/query.dart:148:41)
#5      MappedListIterable.elementAt (dart:_internal/iterable.dart:411:31)
#6      ListIterator.moveNext (dart:_internal/iterable.dart:340:26)
#7      new _GrowableList._ofEfficientLengthIterable (dart:core-patch/growable_array.dart:188:27)
#8      new _GrowableList.of (dart:core-patch/growable_array.dart:150:28)
#9      new List.of (dart:core-patch/array_patch.dart:50:28)
#10     ListIterable.toList (dart:_internal/iterable.dart:211:44)
#11     Query.addRow (package:postgres/src/query.dart:151:30)
#12     _PostgreSQLConnectionStateBusy.onMessage (package:postgres/src/connection_fsm.dart:297:13)
#13     PostgreSQLConnection._readData (package:postgres/src/connection.dart:286:47)
#14     _RootZone.runUnaryGuarded (dart:async/zone.dart:1546:10)
#15     _BufferingStreamSubscription._sendData (dart:async/stream_impl.dart:341:11)
#16     _BufferingStreamSubscription._add (dart:async/stream_impl.dart:271:7)
#17     _SyncStreamControllerDispatch._sendData (dart:async/stream_controller.dart:733:19)
#18     _StreamController._add (dart:async/stream_controller.dart:607:7)
#19     _StreamController.add (dart:async/stream_controller.dart:554:5)
#20     _Socket._onData (dart:io-patch/socket_patch.dart:2144:41)
#21     _RootZone.runUnaryGuarded (dart:async/zone.dart:1546:10)
#22     _BufferingStreamSubscription._sendData (dart:async/stream_impl.dart:341:11)
#23     _BufferingStreamSubscription._add (dart:async/stream_impl.dart:271:7)
#24     _SyncStreamControllerDispatch._sendData (dart:async/stream_controller.dart:733:19)
#25     _StreamController._add (dart:async/stream_controller.dart:607:7)
#26     _StreamController.add (dart:async/stream_controller.dart:554:5)
#27     new _RawSocket.<anonymous closure> (dart:io-patch/socket_patch.dart:1680:33)
#28     _NativeSocket.issueReadEvent.issue (dart:io-patch/socket_patch.dart:1192:14)
#29     _microtaskLoop (dart:async/schedule_microtask.dart:40:21)
#30     _startMicrotaskLoop (dart:async/schedule_microtask.dart:49:5)
#31     _runPendingImmediateCallback (dart:isolate-patch/isolate_patch.dart:120:13)
#32     _RawReceivePortImpl._handleMessage (dart:isolate-patch/isolate_patch.dart:185:5)
PS C:\MyDartProjects\fluent_query_builder> 
isoos
isoos commented on Jan 21, 2022
isoos
on Jan 21, 2022
Owner
@insinfo: I've just found this description: could you please take a look and see if this could fix it for you?
https://www.postgresql.org/docs/current/multibyte.html#id-1.6.11.5.7

Other than that, we'd need to provide a way to specify a PostgreSQLConnection.encoding parameter, which will be passed into parsing and encoding objects. It doesn't seem to be too complex, but if the above automatic server-provided encoding does it for us, it will be simpler in the client code.

insinfo
insinfo commented on Jan 28, 2022
insinfo
on Jan 28, 2022
Author
I've just found this description: could you please take a look and see if this could fix it for you?
https://www.postgresql.org/docs/current/multibyte.html#id-1.6.11.5.7

@isoos
I tried this but it didn't work I keep getting error

import 'dart:io';
import 'package:postgres/postgres.dart';

void main(List<String> args) async {
  var connection = PostgreSQLConnection('192.168.66.5', 5432, 'sistemas',
      username: 'sisadmin', password: 's1sadm1n');

  await connection.open();
  await connection.execute("SET CLIENT_ENCODING TO 'UTF8';");
  // await connection.query("SET CLIENT_ENCODING TO 'UTF8';");

  //
  print('connection.settings: ${connection.settings}');
  var query = '''
    SELECT SUM
	( a1.nr_vaga - a1.nr_vagaefetiv ) AS qtd,
	a3.nm_cargo,
	a1.nm_exigencia 
FROM
	sibem.tb_emprcargo a1,
	sibem.tb_empregador a2,
	sibem.tb_cargo a3 
WHERE
	a1.dt_encerra ISNULL 
	AND ( a1.nr_vaga - a1.nr_vagaefetiv ) > 0 
	AND a1.cd_empregador = a2.cd_empregador 
	AND a1.cd_cargo = a3.cd_cargo 
GROUP BY
	a3.nm_cargo,
	a1.nm_exigencia 
ORDER BY
	a3.nm_cargo
    ''';
  List<List<dynamic>> results = await connection.query(query);
  print('connection.settings: ${connection.settings}');

  for (final row in results) {
    print(row);
  }
  exit(0);
}
PS C:\MyDartProjects\fluent_query_builder> dart run .\example\main2.dart
connection.settings: {client_encoding: UTF8, DateStyle: ISO, MDY, integer_datetimes: on, is_superuser: off, server_encoding: SQL_ASCII, server_version: 8.1.19, session_authorization: sisadmin, standard_conforming_strings: off, TimeZone: UTC}
Unhandled exception:
FormatException: Unexpected extension byte (at offset 1)
#0      _Utf8Decoder.convertSingle (dart:convert-patch/convert_patch.dart:1783:7)
#1      Utf8Decoder.convert (dart:convert/utf.dart:322:42)
#2      Utf8Codec.decode (dart:convert/utf.dart:63:20)
#3      PostgresBinaryDecoder.convert (package:postgres/src/binary_codec.dart:417:21)
#4      Query.addRow.<anonymous closure> (package:postgres/src/query.dart:148:41)
#5      MappedListIterable.elementAt (dart:_internal/iterable.dart:411:31)
#6      ListIterator.moveNext (dart:_internal/iterable.dart:340:26)
#7      new _GrowableList._ofEfficientLengthIterable (dart:core-patch/growable_array.dart:188:27)
#8      new _GrowableList.of (dart:core-patch/growable_array.dart:150:28)
#9      new List.of (dart:core-patch/array_patch.dart:50:28)
#10     ListIterable.toList (dart:_internal/iterable.dart:211:44)
#11     Query.addRow (package:postgres/src/query.dart:151:30)
#12     _PostgreSQLConnectionStateBusy.onMessage (package:postgres/src/connection_fsm.dart:297:13)
#13     PostgreSQLConnection._readData (package:postgres/src/connection.dart:286:47)
#14     _RootZone.runUnaryGuarded (dart:async/zone.dart:1546:10)
#15     _BufferingStreamSubscription._sendData (dart:async/stream_impl.dart:341:11)
#16     _BufferingStreamSubscription._add (dart:async/stream_impl.dart:271:7)
#17     _SyncStreamControllerDispatch._sendData (dart:async/stream_controller.dart:733:19)
#18     _StreamController._add (dart:async/stream_controller.dart:607:7)
#19     _StreamController.add (dart:async/stream_controller.dart:554:5)
#20     _Socket._onData (dart:io-patch/socket_patch.dart:2144:41)
#21     _RootZone.runUnaryGuarded (dart:async/zone.dart:1546:10)
#22     _BufferingStreamSubscription._sendData (dart:async/stream_impl.dart:341:11)
#23     _BufferingStreamSubscription._add (dart:async/stream_impl.dart:271:7)
#24     _SyncStreamControllerDispatch._sendData (dart:async/stream_controller.dart:733:19)
#25     _StreamController._add (dart:async/stream_controller.dart:607:7)
#26     _StreamController.add (dart:async/stream_controller.dart:554:5)
#27     new _RawSocket.<anonymous closure> (dart:io-patch/socket_patch.dart:1680:33)
#28     _NativeSocket.issueReadEvent.issue (dart:io-patch/socket_patch.dart:1192:14)
#29     _microtaskLoop (dart:async/schedule_microtask.dart:40:21)
#30     _startMicrotaskLoop (dart:async/schedule_microtask.dart:49:5)
#31     _runPendingImmediateCallback (dart:isolate-patch/isolate_patch.dart:120:13)
#32     _RawReceivePortImpl._handleMessage (dart:isolate-patch/isolate_patch.dart:185:5)
PS C:\MyDartProjects\fluent_query_builder> 
isoos
isoos commented on Jan 28, 2022
isoos
on Jan 28, 2022
Owner
@insinfo: I've started something very basic, to verify if this would be even feasible. Could you try it out?

You need to depend on the package as git dependency, on the encoding branch (see https://github.com/isoos/postgresql-dart/tree/encoding and https://dart.dev/tools/pub/dependencies#git-packages using the ref keyword).

Create PostgreSQLConnection with encoding: ascii.

Try out some SELECT queries, do not use updates yet, this code only has hooks for decoding values coming from the database.

If that works, we may need to do a bit of refactoring and potentially breaking changes in the API to get this work.

insinfo
insinfo commented on Feb 2, 2022
insinfo
on Feb 2, 2022
Author
when I put "ascii" it gave an error, but when I put "latin1" it worked perfectly.
congratulations excellent work

latin1
PS C:\MyDartProjects\fluent_query_builder> dart run .\example\main2.dart
connection.settings: [[UTF8]]
connection.settings: {client_encoding: UTF8, DateStyle: ISO, MDY, integer_datetimes: on, is_superuser: off, server_encoding: SQL_ASCII, server_version: 8.1.19, session_authorization: sisadmin, standard_conforming_strings: off, TimeZone: UTC}
connection.settings: {client_encoding: UTF8, DateStyle: ISO, MDY, integer_datetimes: on, is_superuser: off, server_encoding: SQL_ASCII, server_version: 8.1.19, session_authorization: sisadmin, standard_conforming_strings: off, TimeZone: UTC}
[1, 2º OFICIAL DE MAQUINAS, OFFSHORE MARITIMO - EXPERIENCIA DE 2 ANO EM CTPS COMO OFICIAL DE MAQUINAS - FORMADO EM CIENCIAS NAUTICAS (STCW REGRA III/I COM 3000KW DE CAPACIDADE) - INGLES AVANCADO]
[1, ACOUGUEIRO, MASCULINO E FEMININO - DE 21 A 42 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - EXPERIENCIA DE PELO MENOS 2 ANOS NA FUNCAO - BOA DICCAO - DINAMICO - ORGANIZADO - PREFERENCIALMENTE MORADOR DO BAIRRO ANCORA OU VIZINHOS - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AJUDANTE, MASCULINO, MAIOR DE 18 ANOS, PARA TRABALHAR COMO AJUDANTE NA AREA DE AR-CONDICIONADO AUTOMOTIVO -  TER EXPERIENCIA NA FUNCAO.]
[1, AJUDANTE DE ACOUGUEIRO, MASCULINO E FEMININO - DE 21 A 42 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - EXPERIENCIA DE PELO MENOS 6 MESES NA FUNCAO - BOA DICCAO - DINAMICO - COMUNICATIVO - EDUCADO - ORGANIZADO - PREFERENCIALMENTE MORADOR DO BAIRRO ANCORA OU VIZINHOS - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AJUDANTE DE CAMINHAO, MASCULINO - A PARTIR DE 22 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - COM DISPOSICAO - PROATIVO - PONTUAL - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AJUDANTE DE CARREGAMENTO, MASCULINO - DE 18 A 35 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - DISPONIBILIDADE DE HORARIO - PONTUAL - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AJUDANTE DE COZINHA, MASCULINO - DE 20 A 45 ANOS - ENSINO FUNDAMENTAL COMPLETO - DESEJAVEL EXPERIENCIA NA AREA - PONTUAL - RESPONSAVEL- COMPROMETIDO - PREFERENCIA POR MORADORES DE CIDADE PRAIANA E ARREDORES - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AJUDANTE DE COZINHA - FREELANCER, MASCULINO/FEMININO, MAIOR DE 18 ANOS, EXPERIENCIA NA FUNCAO. PARA TRABALHAR AOS FINAIS DE SEMANA EM HORARIO NOTURNO - PAGAMENTO POR DIARIA. VAGA REABERTTA.]
[6, AJUDANTE DE PIZZAIOLO, MASCULINO E FEMININO - DE 30 A 60 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - BOM RELACIONAMENTO INTERPESSOAL - DINAMICO - EDUCADO - GENTIL - PROATIVO - DESEJAVEL EXPERIENCIA COMO AJUDANTE DE COZINHA - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, ASSESSOR TECNICO COMERCIAL, MASCULINO E FEMININO - MAIOR DE 18 ANOS - ENSINO MEDIO COMPLETO - DESEJAVEL ESTAR CURSANDO ADM OU ENGENHARIA - DESEJAVEL CONHECIMENTO EM FERRAMENTA CRM - EXPERIENCIA MINIMA DE 2 ANOS EM AREA COMERCIAL, TECNICA - BOM RELACIONAMENTO INTERPESSOAL - CAPACIDADE DE NEGOCIACAO E INFLUENCIA - PROATIVO - ORGANIZADO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, ASSISTENTE DE DEPARTAMENTO PESSOAL, FEMININO - A PARTIR DE 25 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA DE 2 ANOS EM CTPS - PONTUAL - COMPROMETIDA - SOMENTE MORADORA DE RIO DAS OSTRAS, BARRA DE SAO JOAO E/OU UNAMAR.
* LOCAL DE TRABALHO: UNAMAR]
[1, ATENDENTE, MASCULINO - DE 18 A 50 ANOS - ENSINO FUNDAMENTAL - EXPERIENCIA DE PELO MENOS 1 ANO EM CTPS - NAO FUMANTE - NOCOES DE INFORMATICA - EXPERIENCIA EM ATENDIMENTO AO PUBLICO - PREFERENCIALMENTE MORAR EM CIDADE PRAIANA OU CIDADE BEIRA MAR]
[1, ATENDENTE, MASCULINO E FEMININO - DE 18 A 45 ANOS - ENSINO MEDIO COMPLETO - DESEJAVEL EXPERIENCIA NA AREA DE DEPARTAMENTO PESSOAL - ESPIRITO DE LIDERANCA - COMPROMETIDO - PONTUAL - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, ATENDENTE, MASCULINO - MAIOR DE 18 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA DE PELO MENOS 6 MESES COM ATENDIMENTO AO CLIENTE - PONTUAL - ORGANIZADO - COMPROMETIDO - BOA FLUENCIA VERBAL - COMUNICATIVO - PREFERENCIALMENTE MORADORES DE COSTAZUL OU ARREDORES - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, ATENDENTE DE PIZZARIA, FEMININO - MASCULINO - DE 23 A 40 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA EM ATENDIMENTO AO PUBLICO - DESEJAVEL EXPERIENCIA COMO CAIXA - COMUNICATIVA - RESPONSAVEL - PONTUAL - SOMENTE MORADORA DE RIO DAS OSTRAS - PREFERENCIALMENTE QUE MORE PROXIMO AO BAIRRO BELA VISTA E IMEDIACOES]
[1, AUXILIAR ADMINISTRATIVO, MASCULINO E FEMININO - DE 21 A 42 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA DE PELO MENOS 6 MESES NA FUNCAO - EXPERIENCIA COM INFORMATICA (WORD E EXCEL) - BOA DICCAO - DINAMICO - ORGANIZADO - PREFERENCIALMENTE MORADOR DO BAIRRO ANCORA OU VIZINHOS - SOMENTE MORADOR DE RIO DAS OSTRAS]
[2, AUXILIAR ADMINISTRATIVO, MASCULINO E FEMININO - DE 25 A 50 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA DE 1 ANO NA AREA ADMINISTRATIVA - DESEJAVEL CURSOS NA AREA DE AUXILIAR ADMINISTRATIVO E/OU AFINS - DESEJAVEL CONHECIMENTO DO PACOTE OFFICE E EXCEL - PROATIVO - BOA FLUENCIA VERBAL - BOM RELACIONAMENTO INTERPESSOAL - SOMENTE MORADOR DE RIO DAS OSTRAS]
[2, AUXILIAR DE ELETRICA AUTOMOTIVA, MASCULINO, MORADOR DE RIO DAS OSTRAS, MAIOR DE 18 ANOS, PARA TRABALHAR COMO AUXILIAR DE INSTALAÇAO DE PARABRISAS E ACESSORIOS AUTOMOTIVOS. TER EXPERIENCIA NA FUNÇAO.]
[6, AUXILIAR DE INSTALACAO, MASCULINO - MAIOR DE 18 ANOS - ENSINO MEDIO COMPLETO - INDISPENSAVEL A APRESENTACAO DE CNH B (CARRO), EM DIA - DESEJAVEL CURSO TECNICO EM ELETRICA, ELETRONICA, INSTALACAO E/OU AFINS - INICIATIVA - PONTUAL - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AUXILIAR DE MECANICA (SOCORRISTA), MASCULINO - DE 18 A 45 ANOS - ENSINO FUNDAMENTAL COMPLETO - CNH A (MOTO) - SOMENTE MORADOR DE RIO DAS OSTRAS
DESCRICAO: O AUXILIAR DE MECANICA SOCORRISTA IRA (QUANDO NECESSARIO) FAZER TROCAS DE PNEUS E BATERIAS PARA CLIENTES, NA RUA. QUANDO NAO SOLICITADO PARA SOCORRO, IRA TRABALHAR NO ESCRITORIO. ]
[1, AUXILIAR DE PRODUCAO - MASCULINO, MASCULINO, MAIOR DE 18 ANOS, ENSINO MEDIO COMPLETO, MORADOR DE RIO DAS OSTRAS, COM EXP. NA FUNÇAO, TER HABILIDADES MANUAIS E TRABALHAR BEM EM EQUIPE. VAGA REABERTA.]
[1, AUXILIAR DE SERVICOS GERAIS - FEMININO, FEMININO - DE 21 A 42 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - EXPERIENCIA DE PELO MENOS 6 MESES NA FUNCAO - ORGANIZADA - REFERENCIA DOS 3 ULTIMOS EMPREGOS - PREFERENCIALMENTE MORADORA DO BAIRRO ANCORA OU VIZINHOS - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AUXILIAR DE SERVICOS GERAIS - MASCULINO, MASCULINO - DE 20 A 45 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - ORGANIZADO - PONTUAL - PREFERENCIALMENTE QUE MORE PROXIMO AO CENTRO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AUXILIAR DE SERVICOS GERAIS - MASCULINO, MASCULINO - DE 25 A 35 ANOS - ENSINO FUNDAMENTAL COMPLETO - PONTUAL - AGIL - PROATIVO - CNH B (DESEJAVEL) - RESPONSAVEL - DISPONIBILIDADE DE HORARIO - DESEJAVEL EXPERIENCIA EM CARTEIRA]
[1, AUXILIAR DE SERVICOS GERAIS - MASCULINO, MASCULINO - DE 25 A 40 ANOS - ENSINO FUNDAMENTAL COMPLETO - 2 ANOS DE EXPERIENCIA COMPROVADA EM CTPS - DESEJAVEL EXPERIENCIA EM HIGIENIZACAO - PONTUAL - ORGANIZADO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AUXILIAR DE SERVIÇOS GERAIS, MASCULINO E FEMININO - A PARTIR DE 25 ANOS - ENSINO FUNDAMENTAL COMPLETO - PROATIVO - EXPERIENCIA NA FUNCAO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, AUXILIAR DE VENDAS, FEMININO - ATE 38 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA DE 2 ANOS NA FUNCAO - CNH B (CARRO) - EXPERIENTE EM MARKETING EM REDES SOCIAIS - COMPROMETIDA - PONTUAL - EDUCADA - SOMENTE MORADORA DE RIO DAS OSTRAS]
[1, BARBEIRO, MASCULINO, MAIOR DE 18 ANOS, COM EXPERIENCIA NA FUNCAO POR NO MINIMO 01 ANO. ]
[2, CAIXA, FEMININO - DE 21 A 42 ANOS - ENSINO FUNDAMENTAL COMPLETO - EXPERIENCIA DE PELO MENOS 1 ANO NA FUNCAO - BOA DICCAO - DINAMICA - ORGANIZADA - REFERENCIA DOS 3 ULTIMOS EMPREGOS - PREFERENCIALMENTE MORADORA DO BAIRRO ANCORA OU VIZINHOS - SOMENTE MORADOR DE RIO DAS OSTRAS]
[10, CALDEIREIRO, MASCULINO - EXPERIENCIA DE 2 ANOS EM CTPS - DESEJAVEL NIVEL TECNICO - SOMENTE MORADORES DE RIO DAS OSTRAS E/OU MACAE]
[1, CALDEIREIRO, MASCULINO - MAIOR DE 18 ANOS - ENSINO FUNDAMENTAL COMPLETO - EXPERIENCIA COMPROVADA EM CARTEIRA COMO CALDEIREIRO - EXPERIENCIA COM SOLDAGEM, MACARICO PARA CORTE E DOBRA]
[1, CALDEIREIRO ESCALADOR, MASCULINO, MAIOR DE 18 ANOS, COMPROVAR EXPERIENCIA EM CARTEIRA DE TRABALHO. APRESENTAR OS SEGUINTES CERTIFICADOS: CBSP, HUET, NR11, NR12, NR 33 E NR 35.]
[3, CALDEIREIRO ONSHORE, MASCULINO - MAIOR DE 18 ANOS - ENSINO MEDIO (PODENDO SER INCOMPLETO) - EXPERIENCIA MINIMA DE 2 ANOS EM CTPS - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[2, CALDEIREIRO ONSHORE, MASCULINO - MAIOR DE 22 ANOS - ENSINO FUNDAMENTAL COMPLETO - EXPERIENCIA DE PELO MENOS 1 ANO EM CTPS - CERTIFICADO DO CURSO DE CALDEIREIRO - DISPONIBILIDADE DE HORARIO (POSSIBILIDADES DE HORA EXTRA)]
[1, CAMAREIRA, FEMININO - DE 22 A 40 ANOS - ENSINO FUNDAMENTO (PODENDO SER INCOMPLETO) - EXPERIENCIA NA FUNCAO DE CAMAREIRA - PONTUAL - COMPROMETIDA]
[1, CAPTADOR DE IMOVEIS, FEMININO, DE 40 A 55 ANOS, ENSINO MEDIO COMPLETO. DINAMICA E COM BOA CAPACIDADE DE COMUNICAÇAO. NECESSARIO TER NOCOES RELATIVAS A ADMINISTRAÇAO DE IMOVEIS. NECESSARIO VEICULO PROPRIO. ]
[1, COMPRADOR, MASCULINO/FEMININO, ENSINO MEDIO COMPLETO, CURSO NA AREA DE COMPRAS, ENTRE 25 E 35 ANOS, EXPERIENCIA MINIMA DE  UM ANO COMPROVADA EM CARTEIRA. EXPERIENCIA EM NEGOCIAÇAO, INFORMATICA (PACOTE OFFICE), BOA EXPRESSAO ORAL E ESCRITA, FACILIDADE DE FAZER CALCULOS E SER CRITERIOSO. ]
[1, CONFEITEIRA(O), FEMININO OU MASCULINO, MAIOR DE 18 ANOS, COMPROVAR EXPERIENCIA ANTERIOR EM CARTEIRA DE TRABALHO.]
[1, CONSULTOR DE VENDAS, FEMININO E MASCULINO - ENSINO MEDIO COMPLETO - EXPERIENCIA NA AREA COMERCIAL, CONHECIMENTO DE TECNICAS DE VENDAS, CNH AB - VEICULO PROPRIO - HABILIDADE COM SOFTWARES E REDES SOCIAS
ATRIBUICOES: PROSPECCAO DE LEADS, CONDUZIR REUNIOES PARA APRESENTACAO DE PRODUTOS E METODOLOGIA, EFETUAR MATRICULAS, MANTER A ROTINA EM DIA NO CRM (GESTAO DE RELACIONAMENTO COM O CLIENTE), DENTRE OUTRAS.
VAGA PARA MACAE ]
[2, CONSULTOR DE VENDAS EXTERNAS, MASCULINO E FEMININO - ACIMA DE 23 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA COM VENDAS - COMUNICATIVO - RESILIENTE - PERSUASIVO - NEGOCIADOR - SOMENTE MORADOR DE RIO DAS OSTRAS]
[2, CONSULTOR DE VENDAS EXTERNAS, MASCULINO E FEMININO - DE 25 A 48 ANOS - CURSO SUPERIOR OU CURSANDO GESTAO COMERCIAL, MARKETING OU ADMINISTRACAO DE EMPRESAS - EXPERIENCIA COMO CONSULTOR DE VENDAS EXTERNAS - EXPERIENCIA EM ADQUIRENCIA (INTERMEDIACAO DE PAGAMENTOS COM CARTOES DE CREDITO E DEBITOS) - EXPERIENCIA EM EXCEL, POWER POINT, WORD NIVEL INTERMEDIARIO - SOMENTE MORADORES DE RIO DAS OSTRAS, BARRA DE SAO JOAO E/OU TAMOIOS
* OUTROS BENEFICIOS: COMISSOES, CONVENIO COM FACULDADE E CELULAR DA EMPRESA]
[5, CONSULTOR DE VENDAS EXTERNAS, MASCULINO E FEMININO - MAIOR DE 18 ANOS - ENSINO FUNDAMENTAL COMPLETO - NAO EXIGE EXPERIENCIA NA FUNCAO - TREINAMENTO PROPRIO      
OBS: O CANDIDATO TRABALHARA COMO AUTONOMO TENDO A NECESSIDADE DE ABRIR UM MEI (MICRO EMPREENDEDOR INDIVIDUAL) - VENDA DE PROTECAO VEICULAR]
[2, CONSULTOR EXTERNO, FEMININO OU MASCULINO, DE 18 A 25 ANOS, PARA DIVULGAÇAO E VENDA DE CURSOS PROFISSIONALIZANTES. NECESSARIO QUE SEJA UMA PESSOA COMUNICATIVA E COM DISPONIBILIDADE PARA TRABALHAR 4 HORAS DIARIAMENTE - VAGA REABERTA.]
[1, CONTABIL / FISCAL, FEMININO - ATE 38 ANOS - ENSINO MEDIO COMPLETO - DESEJAVEL SUPERIOR EM ADM - EXPERIENCIA DE 3 ANOS NA FUNCAO - COMPROMETIDA - PONTUAL - EDUCADA - SOMENTE MORADORA DE RIO DAS OSTRAS
ATRIBUICOES: SISTEMA DOMINIO, LANCAMENTOS CONTABEIS, FECHAMENTO DE BALANCO PATRIMONIAL ]
[1, CONTADOR, FEMININO - ATE 38 ANOS - EXPERIENCIA DE 3 ANOS NA FUNCAO - COMPROMETIDA - PONTUAL - EDUCADA - SOMENTE MORADORA DE RIO DAS OSTRAS - EXPERIENCIA EM ESCRITURACAO CONTABIL]
[3, COPEIRO(A), FEMININO/MASCULINO, IDADE ENTRE 30 A 45 ANOS, MORADOR DE RIO DAS OSTRAS, NAO FUMANTE, COM EXPERIENCIA EM CARTEIRA, TER CONHECIMENTO EM DRINKS, SUCOS E ETC... ]
[4, CORRETOR DE IMOVEIS, FEMININO E MASCULINO - A PARTIR DE 18 ANOS - TRABALHO AUTONOMO - NAO E EXIGIDO EXPERIENCIA, NEM CRECI ATIVO (EMPREGADOR OFERECE TREINAMENTO)]
[8, CORRETOR DE IMOVEIS, MASCULINO E FEMININO - MAIOR DE 23 ANOS - ENSINO MEDIO COMPLETO - CRESCI ATIVO - COMUNICATIVO - DESEJAVEL CARTEIRA DE CLIENTES]
[1, COZINHEIRO(A), MASCULINO E FEMININO - DE 25 A 45 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA NA FUNCAO (COZINHA COMPLETA - SALADAS - GRELHADOS E FORNO) - ]       
[1, COZINHEIRO(A), MASCULINO E FEMININO (FEMININO ACIMA DE 43 ANOS) - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - EXPERIENCIA DE 3 ANOS - APRESENTAR REFERECIAS DOS 2 ULTIMOS EMPREGOS NA FUNCAO - COMPROMETIDO - PONTUAL]
[1, DENTISTA, FEMININO OU MASCULINO, APRESENTAR COMPROVANTE DE GRADUACAO EM ODONTOLOGIA - PARA TRABALHAR EM QUALQUER DAS SEGUINTES AREAS: CLINICA, CIRURGIA, ENDODONTIA - PARA PARCERIA EM CONSULTORIO MONTADO E EM FUNCIONAMENTO.]
[3, DESENVOLVEDOR, VAGA ONSHORE - AMBOS OS SEXOS - GRADUACAO EM TI, AUTOMACAO, ELETRONICA OU ENGENHARIA DE PRODUCAO - EXPERIENCIA DE PELO MENOS 1 ANO NA AREA DE TI - INGLES AVANCADO - CONHECIMENTO NAS LINGUAGENS C#, ANGULAR, PHYNTON, C++, ETC
ATRIBUICOES: DESENVOLVIMENTO E MELHORIAS DE SOFTWARE, ENTREGA DE SOLUCOES TECNOLOGICAS, ... VAGA SENIO]
[1, DESIGNER DE INTERIOR, MASCULINO E FEMININO - FORMADO EM DESIGNER DE INTERIORES - NECESSARIO EXPERIENCIA EM PROJETOS - DE 25 A 60 ANOS - MORADOR DE RIO DAS OSTRAS OU CIDADE VIZINHA]
[2, DIVULGADOR EXTERNO, FEMININO E MASCULINO - DE 16 A 18 ANOS - OPORTUNIDADE DE 1º EMPREGO - DESEJAVEL ENSINO MEDIO COMPLETO - TRABALHAR COM PANFLETAGEM DE CURSO DE IDIOMAS - MALA DIRETA - CAPTAÇAO DE CONTATOS - AÇOES DIVERSAS - MORADOR DE RIO DAS OSTRAS, BARRA DE SAO JOAO OU UNAMAR]
[1, ELETRICISTA, MASCULINO E FEMININO - A PARTIR DOS 20 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]       
[1, ELETRICISTA, MASCULINO, MAIOR DE 18 ANOS, MORADOR DE RIO DAS OSTRAS, ENSINO MEDIO COMPLETO, COM EXPERIENCIA EM ELETROMECANICA POR NO MINIMO 01 ANO EM CARTEIRA.] 
[1, ENCARREGADO DE OBRA, MASCULINO - MAIOR DE 25 ANOS - ENSINO FUNDAMENTAL COMPLETO - EXPERIENCIA EM TERRAPLANAGEM, ESTRUTURA DE PREDIOS RESIDENCIAIS - ESPIRITO DE LIDERANCA - CORDIAL - PONTUAL - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[8, ENGENHEIRO DE ESTRUTURA DE POÇOS, FEMININO E MASCULINO - NIVEL SUPERIOR COMPLETO EM ENGENHARIA, COM REGISTRO ATIVO NO CREA - EXPERIENCIA COMPROVADA EM CTPS DE 2 ANOS NA AREA DE POÇOS DE PETROLEO OFFSHORE, NAS ATIVIDADES OPERACAO OU PROJETO DE DIMENSIONAMENTO DE REVESTIMENTOS OU EQUIPAMENTOS DE CABECA DE POCOS OU ESTRATEGIA DE CIMENTACAO E TAMPOES DE CIMENTO - EXP EM COMPETENCIA DE DADOS - CONHECIMENTO EM POWER BI - PACOTE DE APLICATIVOS MSOFFICE - NOCOES DE PROJETO DE POCO MARITIMO - NOCOES DE EQUIPAMENTOS DE SONDA DE PERFURACAO - NOCOES BASICAS DE TUBULARES QUE COMPOEM A COLUNA DE REVESTIMENTO - NOCOES BASICAS DE EQUIPAMENTOS DE CABECA DE POCO - NOCOES DE TIPOS DE INICIO DE POCO - NOCOES BASICAS SOBRE CIMENTACAO, RECIMENTACAO E CORRECAO DA CIMENTACAO - NOCOES DE SEGURANCA DE POCO - NOCOES SOBRE CONJUNTO SOLIDARIO DE BARREIRAS - NOCOES DE GEOPRESSOES - NOCOES BASICAS DE WORKOVER E DE ABANDONO]
[2, ENTREGADOR, MASCULINO E FEMININO - MAIOR DE 18 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - CNH A - DESEJAVEL CONHECER RUAS DA CIDADE - PONTUAL - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[5, ESTAGIO - ADMINISTRACAO DE EMPRESAS - SUPERIOR, FEMININO - CURSANDO ENTRE O 1 E 7 SEMESTRE DE ADMINISTRAÇAO - PONTUAL - ORGANIZADA - MORADOR DE RIO DAS OSTRAS, BARRA DE SAO JOAO E *UNAMAR)]
[1, ESTAGIO - CIENCIAS CONTABEIS, FEMININO OU MASCULINO, MAIOR DE 18 ANOS, MORADOR DE RIO DAS OSTRAS, APRESENTAR COMPROVANTE DE MATRICULA ATUAL NO CURSO DE CIENCIAS CONTABEIS A PARTIR DO 6º PERIODO.]
[2, ESTAGIO - CIENCIAS CONTABEIS, MASCULINO E FEMININO - MAIOR DE 18 ANOS - ESTAR CURSANDO A PARTIR DO 6º PERIODO DE CIENCIAS CONTABEIS - PROATIVO - COMUNICATIVO - ORGANIZADO - PONTUAL - SOMENTE MORADOR DE UNAMAR E E BUZIOS]
[1, ESTAGIO DE ADMINISTRAÇAO, MASCULINO E FEMININO - MAIOR DE 18 ANOS - CURSANDO ENTRE O 1º E 8º PERIODO DE ADMINISTRACAO - SOMENTE MORADORES DE RIO DAS OSTRAS]     
[1, ESTAGIO - DESENVOLVIMENTO E CIENCIA DE DADOS, MASCULINO E FEMININO - FORMACAO ACADEMICA EM ANALISE DE SISTEMAS, CIENCIA DA COMPUTACAO, SISTEMA DA INFORMACAO, ENGENHARIA EM GERAL OU AFINS. - CONCLUSAO DA GRADUACAO EM 2022 - INGLES INTERMEDIARIO OU AVANCADO
* VAGA DISPONIVEL TAMBEM PARA PCD (PESSOA COM DEFICIENCIA)]
[1, ESTAGIO - INFRA ESTRUTURA / CLOUD, MASCULINO E FEMININO - FORMACAO ACADEMICA EM ANALISE DE SISTEMA, CIENCIA DA COMPUTACAO, ENGENHARIA DA COMPUTACAO, ENGENHARIA DE CONTROLE E AUTOMACAO OU AFINS - CONCLUSAO DA GRADUACAO EM DEZEMBRO DE 2022 - INGLES INTERMEDIARIO OU AVANCADO - EXPERIENCIA COM OS SISTEMAS LINUX, WINDOWS, HARDWARE MAINTENANCE, MSSQL SERVER OU ORACLE (SENDO UM DIFERENCIAL)
* VAGA DISPONIVEL TAMBEM PARA PCD (PESSOA COM DEFICIENCIA)]
[2, ESTAGIO - PRODUTOR DE MIDIA, MASCULINO E FEMININO - DE 18 A 29 ANOS - ESTAR CURSANDO GRADUACAO EM MARKETING, PUBLICIDADE E/OU COMUNICACAO SOCIAL - CONHECIMENTO DE FERRAMENTAS DE PRODUCAO GRAFICA (PACOTE ADOBE, CANVAS E/OU INFINITY) - CONHECIMENTO DE FERRAMENTAS DE EDICAO DE VIDEO (ADOBE, DAVINCI RESOLVE E/OU VEGAS PRO) - BOA ESCRITA - BOA COMUNICACAO - CRIATIVO - CAPACIDADE DE CUMPRIR PRAZOS - TER E ENVIAR PORTFOLIO
* APOS EFETIVADO, O COLABORADOR IRA UMA VEZ POR SEMANA, NA EMPRESA.]
[2, ESTAGIO - TECNICO OPERACIONAL, MASCULINO E FEMININO - DE 20 A 29 ANOS - ENSINO MEDIO COMPLETO - ESTAR CURSANDO TECNICO EM MANUTENCAO INDUSTRIAL, MECANICA, MECATRONICA, ELETROTECNICA, ELETRICA, ELETRONICA, ELETROMECANICA, EDIFICAÇOES, SANEAMENTO E/OU AUTOMACAO INDUSTRIAL - NO CASO DE SUPERIOR INCOMPLETO ESTAR CURSANDO ENGENHARIA EM GERAL]
[1, FARMACEUTICO(A), FEMININO OU MASCULINO, MAIOR DE 18 ANOS, NECESSARIO ENSINO SUPERIOR EM FARMACIA - APRESENTAR CRF ATIVO. ]
[1, FISCAL DE PREVENCAO E PERDAS, FEMININO OU MASCULINO, MAIOR DE 21 ANOS, SOMENTE MORADOR DE RIO DAS OSTRAS (APRESENTAR COMPROVANTE ATUAL), APRESENTAR / COMPROVAR ENSINO MEDIO COMPLETO. APRESENTAR / COMPROVAR EXPERIENCIA NA FUNCAO. APRESENTAR CURRICULO IMPRESSO.]
[1, FISIOTERAPEUTA (RPG), MASCULINO E FEMININO - MAIOR DE 23 ANOS - FORMADO EM FISIOTERAPIA COM CURSO DE RPG - PONTUAL - COMPROMETIDO - DISPONIBILIDADE DE HORARIO ] 
[1, FRESADOR, MASCULINO E FEMININO - ATE 30 ANOS - ENSINO FUNDAMENTAL COMPLETO - CURSO DE FRESADOR (OU CURSANDO) - SEM EXPERIENCIA EXIGIDA - DISPONIBILIDADE PARA HORA EXTRA - COMPROMETIDO - PONTUAL - PREFERENCIALMENTE MORADOR DE RIO DAS OSTRAS]
[1, GARCOM -  FREELANCER, MASCULINO , MAIOR DE 18 ANOS, EXPERIENCIA NA FUNCAO. PARA TRABALHAR AOS FINAIS DE SEMANA EM HORARIO NOTURNO - PAGAMENTO POR DIARIA. VAGA REABERTA.]
[4, GARCOM/GARCONETE, MASCULINO E FEMININO - MAIOR DE 18 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - EXPERIENCIA DE PELO MENOS 1 ANO - BOM RELACIONAMENTO INTERPESSOAL - COMUNICATIVO - EDUCADO - GENTIL - PROATIVO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, GARÇOM, MASCULINO - MAIOR DE 18 ANOS - ENSINO FUNDAMENTAL COMPLETO - PONTUAL - EXTROVERTIDO - SIMPATICO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, GARÇOM, MASCULINO, MAIOR DE 18 ANOS, MORADOR DE RIO DAS OSTRAS, TER EXPERIENCIA NA FUNÇAO, ENSINO MEDIO COMPLETO.]
[1, GERENTE COMERCIAL DE VENDAS, MASCULINO E FEMININO - A PARTIR DE 30 ANOS - ENSINO MEDIO COMPLETO (DESEJAVEL SUPERIOR) - CONHECIMENTOS EM INFORMATICA - DESEJAVEL EXPERIENCIA NA GERENCIA DE LOJA DE ELETROS E MOVEIS (VAREJO) - PROATIVO - COMUNICATIVO - ORGANIZADO - MOTIVADOR/INCENTIVADOR - DINAMICO - ESTRATEGISTA EM RELAÇAO A AMBIENTES MACRO E MICRO, ALEM DE CRIATIVO NA CAPTACAO DE CLIENTES - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[2, INSPETOR DE PINTURA, MASCULINO E FEMININO - ENSINO MEDIO COMPLETO - IDADE INFERIOR A 59 ANOS - CURSO DE INSPETOR TECNICO EM CORDAS N3 (IRATA) - EXPERIENCIA OFFSHORE DE PELO MENOS 1 ANO (COMPROVAR) - EXPERIENCIA COMO INSPETOR DE PINTURA (COMPROVAR) - APRESENTAR HUET E CBSP EM DIA - ESTAS EM DIA COM PELO MENOS 2 DOSES DA VACINA CONTRA COVID-19 - POSSUIR LOGBOOK, COMO N3]
[1, INSPETOR DE PINTURA, MASCULINO - FORMACAO TECNICA OU SUPERIOR NA AREA OU AFINS - CFT ATUALIZADO E EM DIA - EXPERIENCIA DE 5 ANOS EM CTPS - CONHECIMENTO DO PACOTE OFFICE - APRESENTACAO DOS CERTIFICADOS HABILITADOS E ATUALIZADOS PARA EXERCICIO DA PROFISSAO
DENTRE AS HABILIDADES E COMPETENCIAS: SER COMUNICATIVO, ORGANIZADO, DINAMICO,  COMPROMETIDO, RESPONSAVEL; ALEM DE TER CONCENTRACAO, EQUILIBRIO E ESPIRITO DE LIDERANCA - SOMENTE MORADORES DO ESTADO DO RJ]
[2, INSPETOR DE PINTURA ESCALADOR N1, VAGA OFFSHORE - FEMININO E MASCULINO - ENSINO MEDIO COMPLETO - QUALIFICACAO EM INSPECAO DE PINTURA (SNQC-CP OU CEBRAPI) - EXPERIENCIA COMPROVADA EM CTPS - EXPERIENCIA EM LIDERANCA DE EQUIPE - IRATA E CBSP VALIDOS - DESEJAVEL T-HUET (HOMOLOGADO PELA OPITO)]
[1, INSPETOR DE PINTURA - IRATA N1, MASCULINO - FORMACAO TECNICA OU SUPERIOR NA AREA OU AFINS - CFT ATUALIZADO E EM DIA - EXPERIENCIA DE 5 ANOS EM CTPS - CONHECIMENTO DO PACOTE OFFICE - APRESENTACAO DOS CERTIFICADOS HABILITADOS E ATUALIZADOS PARA EXERCICIO DA PROFISSAO
DENTRE AS HABILIDADES E COMPETENCIAS: SER COMUNICATIVO, ORGANIZADO, DINAMICO,  COMPROMETIDO, RESPONSAVEL; ALEM DE TER CONCENTRACAO, EQUILIBRIO E ESPIRITO DE LIDERANCA - SOMENTE MORADORES DO ESTADO DO RJ]
[1, INSPETOR DE SOLDA LP/PM, MASCULINO - FORMACAO TECNICA OU SUPERIOR NA AREA OU AFINS - CFT ATUALIZADO E EM DIA - EXPERIENCIA DE 5 ANOS EM CTPS - CONHECIMENTO DO PACOTE OFFICE - APRESENTACAO DOS CERTIFICADOS HABILITADOS E ATUALIZADOS PARA EXERCICIO DA PROFISSAO
DENTRE AS HABILIDADES E COMPETENCIAS: SER COMUNICATIVO, ORGANIZADO, DINAMICO,  COMPROMETIDO, RESPONSAVEL; ALEM DE TER CONCENTRACAO, EQUILIBRIO E ESPIRITO DE LIDERANCA - SOMENTE MORADORES DO ESTADO DO RJ]
[1, INSPETOR DE SOLDA LP/PM - IRATA N1, MASCULINO - FORMACAO TECNICA OU SUPERIOR NA AREA OU AFINS - CFT ATUALIZADO E EM DIA - EXPERIENCIA DE 5 ANOS EM CTPS - CONHECIMENTO DO PACOTE OFFICE - APRESENTACAO DOS CERTIFICADOS HABILITADOS E ATUALIZADOS PARA EXERCICIO DA PROFISSAO
DENTRE AS HABILIDADES E COMPETENCIAS: SER COMUNICATIVO, ORGANIZADO, DINAMICO,  COMPROMETIDO, RESPONSAVEL; ALEM DE TER CONCENTRACAO, EQUILIBRIO E ESPIRITO DE LIDERANCA - SOMENTE MORADORES DO ESTADO DO RJ]
[1, INSPETOR DE SOLDA N1 LP/PM ESCALADOR, VAGA ONSHORE (COM EMBARQUES ESPORADICOS) - MASCULINO - ENSINO MEDIO COMPLETO - QUALIFICACAO EM INSPECAO DE SOLDA (NIVEL 1), PELA FBTS - QUALIFICAO EM LP/PM, PELA ABENDE - QUALIFICACAO EM ACESSO POR CORDAS N1 (IRATA, ABENDI OU ANEAC) - CBSP E HUET VALIDOS - EXPERIENCIA COMPROVADA EM CTPS]
[1, INSPETOR US-N2-S2.1/S4, MASCULINO - FORMACAO TECNICA OU SUPERIOR NA AREA OU AFINS - CFT ATUALIZADO E EM DIA - EXPERIENCIA DE 5 ANOS EM CTPS - CONHECIMENTO DO PACOTE OFFICE - APRESENTACAO DOS CERTIFICADOS HABILITADOS E ATUALIZADOS PARA EXERCICIO DA PROFISSAO
DENTRE AS HABILIDADES E COMPETENCIAS: SER COMUNICATIVO, ORGANIZADO, DINAMICO,  COMPROMETIDO, RESPONSAVEL; ALEM DE TER CONCENTRACAO, EQUILIBRIO E ESPIRITO DE LIDERANCA - SOMENTE MORADORES DO ESTADO DO RJ]
[1, INSPETOR US-N2-S2.1/S4 - IRATA N1, MASCULINO - FORMACAO TECNICA OU SUPERIOR NA AREA OU AFINS - CFT ATUALIZADO E EM DIA - EXPERIENCIA DE 5 ANOS EM CTPS - CONHECIMENTO DO PACOTE OFFICE - APRESENTACAO DOS CERTIFICADOS HABILITADOS E ATUALIZADOS PARA EXERCICIO DA PROFISSAO
DENTRE AS HABILIDADES E COMPETENCIAS: SER COMUNICATIVO, ORGANIZADO, DINAMICO,  COMPROMETIDO, RESPONSAVEL; ALEM DE TER CONCENTRACAO, EQUILIBRIO E ESPIRITO DE LIDERANCA - SOMENTE MORADORES DO ESTADO DO RJ]
[2, INSTALADOR DE PARABRISAS E ACESSORIOS, MASCULINO, MAIOR DE  25 ANOS, MORADOR DE RIO DAS OSTRAS, COM EXPERIENCIA NA FUNÇAO.]
[15, INSTRUMENTISTA INDUSTRIAL, MASCULINO, MAIOR DE 18 ANOS, MORADOR DE RIO DAS OSTRAS, CURSO TECNICO, CFT, COM EXPERIENCIA DE 3 ANOS COMPROVADA.]
[3, INTERPRETE DE LIBRAS, MASCULINO OU FEMININO - MAIOR DE 22 ANOS - SUPERIOR COMPLETO EM QUALQUER AREA DO CONHECIMENTO - EXPERIENCIA COMO INTERPRETE DE LIBRAS      
ATRIBUICOES: IRA ATUAR EM UNIVERSIDADE EM MACAE FAZENDO TRADUCOES E INTERPRETACAO PARA LIBRAS - ACOMPANHAR SERVIDOR OU ALUNO SURDO - INTERPRETACAO SIMULTANEA DO PORTUGUES PARA LIBRAS, DE AULAS, PALESTRAS E REUNIOES.]
[2, JARDINEIRO, MASCULINO - DE 30 A 55 ANOS - ENSINO FUNDAMENTAL COMPLETO - EXPERIENCIA NA AREA DE JARDINAGEM (E ROCADEIRA) - COMPROMETIDO - PONTUAL - SOMENTE MORADOR DE RIO DAS OSTRAS]
[2, JOVEM APRENDIZ, MASCULINO E FEMININO - DE 19 A 24 ANOS (EM CASO DE MENOR DE IDADE NECESSARIO AUTORIZACAO DOS PAIS) - ENSINO MEDIO, TECNICO OU FORMADO
VAGAS NOS SETORES DE RH E PROJETOS - DESEJAVEL CURSOS DO SENAC - PERFIL ADMINISTRATIVO E OPERACIONAL]
[1, JOVEM APRENDIZ - ADM, MASCULINO - ENSINO MEDIO COMPLETO
* VAGA DE JOVEM APRENDIZ - DE 14 A 24 ANOS, PARA TRABALHAR EM RIO DAS OSTRAS, NA AREA ADMINISTRATIVA]
[1, LAVADOR, MASCULINO OU FEMININO - MAIOR DE 18 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - DISPONIBILIDADE DE HORARIO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, LAVADOR DE AUTOMOVEIS DELIVERY, MASCULINO, MAIOR DE 18 ANOS, DESEJAVEL QUE  MORE EM BAIRRO PROXIMO A MARILEA, TER CNH B, O CANDIDATO PASSARA POR TREINAMENTO.]   
[2, LIMPADOR DE VIDROS, MASCULINO, MORADOR DE RIO DAS OSTRAS, IDADE ENTRE 18 E 55 ANOS, MOTO PROPRIA, CNH"A", NAO E NECESSARIO EXPERIENCIA; EMPRESA DA TREINAMENTO.] 
[1, MANICURE, FEMININO, MAIOR DE 18 ANOS, COM EXPERIENCIA NA FUNÇAO E DISPONIBILIDADE DE HORARIO. SERA FEITO TESTE.]
[1, MANICURE - ACRIGEL, FEMININO, MAIOR DE 18 ANOS, MORADORA DE RIO DAS OSTRAS, COM EXPERIENCIA  EM ALONGAMENTO DE UNHAS. SERA FEITO TESTE PRATICO. PREFERENCIALMENTE MORADORA DO BAIRRO MARILEIA E ADJACENCIAS]
[1, MANICURE - ACRIGEL, FEMININO, MAIOR DE 18 ANOS, NAO FUMANTE, ESPECIALISTA EM UNHAS DE ACRIGEL, VIDRO E GEL MOLDADO.]
[1, MANICURO, MASCULINO, MAIOR DE 18 ANOS, COM EXPERIENCIA NA FUNÇAO E DISPONIBILIDADE DE HORARIO. SERA FEITO TESTE.]
[1, MARCENEIRO, MASCULINO - MAIOR DE 18 ANOS - NECESSARIO EXPERIENCIA EM CORTE DE MOVEIS MDF - PONTUAL - ORGANIZADO - COMPROMETIDO]
[1, MECANICO (AUTO), MASCULINO - A PARTIR DE 20 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - COMPROMETIDO - PONTUAL - SOMENTE MORADOR DE RIO DAS OSTRAS]     
[1, MECANICO DE AUTOMOVEIS A DIESEL, MASCULINO - MAIOR DE 18 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - EXPERIENCIA DE PELO MENOS 1 ANO - SOMENTE MORADOR DE RIO DAS OSTRAS OU MACAE]
[2, MONTADOR DE MOVEIS, MASCULINO - DE 22 A 60 ANOS - ENSINO MEDIO (PODENDO SER INCOMPLETO) - EXPERIENCIA COMPROVADA EM CTPS, DE 1 ANO NA FUNCAO - PONTUAL - COMPROMETIDO - MONTADOR COM EXPERIENCIA EM: PVC, DRYWALL, EUCATEX, PISO LAMINADO E AFINS - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, MOTORISTA - CNH A/B, MASCULINO - DE 25 A 40 ANOS - ENSINO MEDIO COMPLETO - CNH A/B (EM DIA) - PONTUAL - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS
OBS: A EMPRESA FORNECE OS VEICULOS.]
[2, MOTORISTA - CNH D, MASCULINO - A PARTIR DE 22 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - EXPERIENCIA DE PELO MENOS 1 ANO NA CTPS - PONTUAL - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[6, OPERADOR DE LOJA - UNAMAR, SEXO MASCULINO - DE 23 A 35 ANOS - COMPROVAR ENSINO MEDIO COMPLETO - POSSUIR PELO MENOS 1 ANO DE EXPERIENCIA NA AREA, NA CTPS - POSSUIR CARTA DE RECOMENDACAO OU CONTATO DO GESTOR DA ULTIMA OCUPACAO - SOMENTE MORADOR DE UNAMAR]
[4, OPERADOR DE MAQUINAS, MASCULINO - MAIOR DE 18 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA DE PELO MENOS 1 ANO E 6 MESES, COM OPERACAO DE MAQUINAS E AFINS - DESEJAVEL TECNICA EM MECANICA, ELETRICA, ELETROMECANICA OU AUTOMACAO - DESEJAVEL CBSP E HUET VALIDOS - CNH B - DESEJAVEL CURSO DE MOVIMENTACAO DE CARGAS - DISPONIBILIDADE PARA VIAGENS - PROATIVO - ORGANIZADO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[19, OPERADOR DE ROV, OFFSHORE - OPERADOR DE ROV PLENO E SENIOR - TECNICO EM ELETRONICA, ELETROTECNICA, ELETRICA, MECATRONICA OU SIMILAR - REGISTRO NO CFT - EXPERIENCIA DE 1 ANO NA CTPS COMO PILOTO - NECESSARIO CBSP E HUET ATIVOS
ATRIBUICOES: MANUTENCAO E OPERACAO DOS VEICULO, NO MAR.]
[1, ORCAMENTISTA, MASCULINO OU FEMININO - ENSINO MEDIO COMPLETO - MAIOR DE 25 ANOS - EXPERIENCIA MINIMA DE 2 ANOS EM ORCAMENTOS PARA A PETROBRAS E DEMAIS ORGAOS PUBLICOS - CONHECIMENTO E UTILIZACAO DAS FERRAMENTAS PETRONECT E COMPRASNET - CONHECIMENTO ABRANGENTE NAS DICIPLINAS: CIVIL, ESTRUTURAS, TUBULACAO, ELETRICA E INSTRUMENTACAO - DISPONIBILIDADE PARA VIAGENS]
[1, PADEIRO, MASCULINO - DE 18 A 55 ANOS - ENSINO FUNDAMENTAL (PODENDO SER INCOMPLETO) - EXPERIENCIA NA FUNCAO - COMPROMISSADO - PONTUAL - PREFERENCIALMENTE MORADORES DO BAIRRO ANCORA OU BAIRROS VIZINHOS - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, PADEIRO, MASCULINO - DE 21 A 60 ANOS - DESEJAVEL ENSINO MEDIO - EXPERIENCIA NA AREA - ASSIDUO - COMPROMETIDO - PONTUAL - SOMENTE MORADOR DE RIO DAS OSTRAS]      
[1, PADEIRO/CONFEITEIRO, MASCULINO, MAIOR DE 18 ANOS, MORADOR DE RIO DAS OSTRAS, IDADE  ENTRE 23 E 50 ANOS, ENSINO FUNDAMENTAL COMPLETO, COM EXPERIENCIA EM 2 ANOS COMPROVADA EM CARTEIRA DE TRABALHO.]
[1, PASTELEIRO, MASCULINO/FEMININO, MAIOR DE 18 ANOS, MORADOR DE RIO DAS OSTRAS, COM EXPERIENCIA NA FUNÇAO.]
[1, PINTOR AUTOMOTIVO, MASCULINO - DE 25 A 55 ANOS - DESEJAVEL FUNDAMENTAL COMPLETO - ATRIBUIÇOES: PINTAR CARROCERIAS DOS VEICULOS DA FROTA - EXPERIENCIA DE 6 MESES EM CTPS]
[1, PIZZAIOLLO, MASCULINO - DE 25 A 55 ANOS - 2º GRAU COMPLETO - 5 ANOS DE EXPERIENCIA COMPROVADA EM CTPS OU CARTA DE REFERENCIA QUE CHEGUE A ESTE TEMPO - PONTUAL - AGIL - ORGANIZADO - PRO ATIVO - SOMENTE MORADOR DE RIO DAS OSTRAS (VAGA REABERTA)]
[1, PROFESSOR DE EDUCACAO FISICA, MASCULINO/FEMININO, MORADOR DE RIO DAS OSTRAS, IDADE ENTRE 20 E 40 ANOS, SOLTEIRO(A), SEM FILHOS,  COM EXPERIENCIA NA FUNÇAO.]     
[1, PROFESSOR DE INGLES, FEMININO OU MASCULINO, MAIOR DE 18 ANOS, INGLES FLUENTE, COMPROVAR EXPERIENCIA MINIMA DE 01 ANO EM SALA DE AULA NO IDIOMA INGLES NOS SISTEMAS REGULARES, INDIVIDUALIZADOS E PARTICULARES PARA TODAS AS IDADES, APRESENTAR CERTIFICADO DO CURSO DE INGLES OU CERTIFICAÇAO INTERNACIONAL, DESEJAVEL NIVEL SUPERIOR, RESIDENTE EM RIO DAS OSTRAS ]
[1, REPOSITOR, MASCULINO OU FEMININO - DE 21 A 45 ANOS - ENSINO MEDIO COMPLETO -  CNH A (MOTO), COM MAIS DE 1 ANO (EXPERIENCIA EM TRANSITO, COM MOTO) - EXPERIENCIA NA FUNÇAO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[2, REPRESENTANTE COMERCIAL, MASCULINO E FEMININO - MAIOR DE 23 ANOS - ENSINO MEDIO COMPLETO - PERFIL COMERCIAL E RELACIONAL - FACILIDADE COM FERRAMENTAS DE PESQUISA COMO "EXACT SALES" OU SIMILAR) - BOA FLUENCIA VERBAL - NOÇOES DE SUSTENTABILIDADE - VENDA DE SERVIÇOS RELACIONADOS A SISTEMA DE ECONOMIA DE AGUA - VAGA PARA MACAE - FORMATO REMOTO E PRESENCIAL]
[1, REPRESENTANTE COMERCIAL, MASCULINO OU FEMININO - DE 25 A 50 ANOS - DESEJAVEL ENSINO MEDIO COMPLETO - COMPROMETIDO - AMBICIOSO - COMUNICATIVO - DINAMICO - PROATIVO - DESEJAVEL EXPERIENCIA EM TRABALHO COM METAS E RESULTADOS - EXPERIENCIA COM VENDAS EXTERNAS - POSSUI VEICULO PROPRIO, PREFERENCIALMENTE MOTO E DOCUMENTO EM DIA - ]
[1, SERRADOR P/ GRANITO, MASCULINO, MORADOR DE RIO DAS OSTRAS, MAIOR DE 18 ANOS, TER EXPERIENCIA NA FUNÇAO.]
[10, SOLDADOR, MASCULINO - EXPERIENCIA DE 2 ANOS EM CTPS - EXPERIENCIA COM TIG, MIG E ELETRODO - DESEJAVEL NIVEL TECNICO - SOMENTE MORADORES DE RIO DAS OSTRA E/OU MACAE - LOCAL DE TRABALHO: IMBOASSICA]
[1, SOLDADOR ESCALADOR, MASCULINO, MAIOR DE 18 ANOS, NECESSARIO COMPROVAR EXPERIENCIA EM CARTEIRA DE TRABALHO, APRESENTAR OS SEGUINTES CERTIFICADOS: CBSP, HUET, IRATA, QUALIFICACAO EM SLDA ER/TIG.]
[4, SOLDADOR ESCALADOR N1, VAGA OFFSHORE - MASCULINO E FEMININO - ENSINO FUNDAMENTAL COMPLETO - EXPERIENCIA COMO SOLDADOR DE LIGAS ESPECIAS - CERTIFICADO DE ACESSO POR CORDAS N1 (IRATA, ABENDI OU ANEAC) - CBSP VALIDO - EXPERIENCIA COMPROVADA EM CTPS (TIGER, CUNI, SUPER DUPLEX/ALUMINIO, AC, ACO INOXIDAVEL) - DESEJAVEL T-HUET OU HUIET (SOMENTE SERAO ACEITOS OS TREINAMENTOS  REALIZADOS EM INTITUICOES CREDENCIADAS PELA OPITO)]
[1, SUPERVISORA DE VENDAS, MASCULINO OU FEMININO, ACIMA DE 21 ANOS, COMPROVAR ENSINO MEDIO COMPLETO, 2 ANOS DE EXPERIENCIA COMPROVADA EM CARTEIRA DE TRABALHO.]      
[1, SUPERVISOR COMERCIAL, MASCULINO E FEMININO - DE 25 A 40 ANOS - ENSINO MEDIO COMPLETO - PONTUAL - DISCRETO - EDUCADO - COMUNICATIVO - MORADOR DE RIO DAS OSTRAS, BARRA DE SAO JOAO OU UNAMAR - ATRIBUIÇOES (ABERTURA E MANUTENÇAO DE PARCERIAS, CAPTACAO DE CONTATOS, AÇOES EXTERNAS, TREINAMENTO E ACOMPANHAMENTO DE EQUIPE, TELEMARKETING, PREENCHIMENTO DE PLANILHAS E MATRICULAS) - EXPERIENCIA NA AREA DE CURSOS DE IDIOMAS]
[1, SUPERVISOR DE VENDAS EXTERNAS, FEMININO OU MASCULINO, IDADE DE 25 A 50 ANOS, ENSINO MEDIO COMPLETO,  PARA TRABALHAR COMO SUPERVISOR DE VENDAS DE PRODUTOS DE LIMPEZA, EMBALAGENS, DESCARTAVEIS, EPIS E PAPELARIA NO MUNICIPIO DE RIO DAS OSTRAS COM AREAS DE ATUACAO PRE DEFINIDAS. IMPRESCINDIVEL QUE TENHA EXPERIENCIA EM SUPERVISAO OU GERENCIA DE EQUIPES POR 1 ANO E MEIO.CONTRATAÇAO POR MEI.]
[1, SUPERVISOR IRATA N3, MASCULINO - FORMACAO TECNICA OU SUPERIOR NA AREA OU AFINS - CFT ATUALIZADO E EM DIA - EXPERIENCIA DE 5 ANOS EM CTPS - CONHECIMENTO DO PACOTE OFFICE - APRESENTACAO DOS CERTIFICADOS HABILITADOS E ATUALIZADOS PARA EXERCICIO DA PROFISSAO
DENTRE AS HABILIDADES E COMPETENCIAS: SER COMUNICATIVO, ORGANIZADO, DINAMICO,  COMPROMETIDO, RESPONSAVEL; ALEM DE CONCENTRACAO, EQUILIBRIO E ESPIRITO DE LIDERANCA - SOMENTE MORADORES DO ESTADO DO RJ]
[1, TECNICO DE AR CONDICIONADO AUTOMOTIVO, MASCULINO, MAIOR DE 18 ANOS, MORADOR DE RIO DAS OSTRAS, COM EXPERIENCIA NA FUNCAO.]
[4, TECNICO DE MANUTENÇAO EM INSTRUMENTACAO, MASCULINO E FEMININO - DE 24 A 55 ANOS - FORMAÇAO TECNICA COMPLETA (DE NIVEL MEDIO) - EXPERIENCIA COMPROVADA EM CTPS DE 5 ANOS - CURSO TECNICO DO SENAI OU EQUIVALENTE - MORADOR DE RIO DAS OSTRAS TERA TRANSPORTE FRETADO PELA EMPRESA]
[1, TECNICO DE MATERIAIS, VAGA TEMPORARIA (9 MESES) - MASCULINO - ENSINO MEDIO COMPLETO - CURSO DE MOVIMENTACAO DE CARGAS - EXPERIENCIA DE PELO MENOS 6 MESES NA AREA
* PLANO DE SAUDE EXTENSO A FAMILIA]
[1, TECNICO DE PROCESSOS PLENO, MASCULINO E FEMININO - MAIOR DE 20 ANOS - ENSINO MEDIO COMPLETO - TECNICO NA AREA DE INDUSTRIA - INGLES INTERMEDIARIO - EXPERIENCIA EM MANUTENCAO, EM MECANICA INDUSTRIAL - DIFERENCIAL SERA CONHECIMENTO DE EQUIPAMENTOS DE SUBMARINO
ATRIBUICOES: SUPORTE NA MANUFATURA RELACIONADA A MONTAGEM, USINAGEM, SOLDAGEM E REVESTIMENTO.]
[1, TECNICO DE REFRIGERACAO, MASCULINO, MORADOR DE RIO DAS OSTRAS, MAIOR DE 18 ANOS, COM EXPERIENCIA EM MANUTENÇAO DE GELADEIRAS, FREEZERS E FRIGOBAR]
[2, TECNICO EM MECANICA, MASCULINO, MAIOR DE 18 ANOS, ESTAR COM CFT VALIDO, HABILITAÇAO (B) OU  (D), COM EXPERIENCIA EM MECANICA AUTOMOTIVA.]
[1, TECOP JR, OFFSHORE (ROV) -  MASCULINO E FEMININO - ENSINO TECNICO - SUPERIOR DESEJAVEL - EXPERIENCIA DE 3 ANOS EM CTPS, EM OPERACOES OFFSHORE ROV E SUREY - INGLES E UM GRANDE DIFFERENCIAL
ATRIBUICOES: SUPORTE AO GERENTE DA EMBARCACAO - ORIENTA EQUIPE DE ROV - DEFINE PROCEDIMENTOS DA OPERACAO - CONTATO COM CLIENTES - DENTRE OUTROS]
[10, TELEMARKETING, MASCULINO E FEMININO - DE 20 A 45 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA COM VENDAS - BOA FLUENCIA VERBAL - COMUNICATIVO - CRIATIVO - NECESSARIO PERFIL DE VENDEDOR E VONTADE DE CRESCER - EXPERIENCIA COM VENDAS DE EMPRESTIMOS CONSIGNADOS SERA UM DIFERENCIAL - SOMENTE MORADOR DE RIO DAS OSTRAS - INICIO IMEDIATO]
[1, TORNEIRO, MASCULINO E FEMININO - ATE 30 ANOS - ENSINO FUNDAMENTAL COMPLETO - CURSO DE TORNEIRO (OU CURSANDO) - SEM EXPERIENCIA EXIGIDA - DISPONIBILIDADE PARA HORA EXTRA - COMPROMETIDO - PONTUAL - PREFERENCIALMENTE MORADOR DE RIO DAS OSTRAS]
[1, VENDEDOR, FEMININO OU MASCULINO, SOMENTE MORADOR DE RIO DAS OSTRAS, COMPROVAR EXPERIENCIA ANTERIOR COMO VENDEDOR EM LOJA DE MOVEIS OU COLCHOES. IDADE ENTRE 25 E 40 ANOS, ENSINO MEDIO COMPLETO.  VAGA REABERTA.]
[2, VENDEDOR, MASCULINO E FEMININO - A PARTIR DE 25 ANOS - ENSINO MEDIO COMPLETO - CONHECIMENTOS EM INFORMATICA - DESEJAVEL EXPERIENCIA COM VENDAS NA AREA DE ELETROS E MOVEIS (VAREJO) - PROATIVO - COMUNICATIVO - ORGANIZADO - DINAMICO - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, VENDEDOR, MASCULINO E FEMININO - DE 18 A 25 ANOS - ENSINO MEDIO COMPLETO - PONTUAL -  EDUCADO - COMUNICATIVO - MORADOR DE RIO DAS OSTRAS, BARRA DE SAO JOAO OU UNAMAR - ATRIBUIÇOES (TELEMARKETING, MATRICULAS, ACOES EXTERNAS E INTERNAS, DIVULGAÇOES EM REDES SOCIAIS) - DESEJAVEL EXPERIENCIA NA AREA DE CURSOS DE IDIOMA]
[10, VENDEDOR, MASCULINO E FEMININO - MAIOR DE 18 ANOS - ENSINO MEDIO (PODENDO SER INCOMPLETO) - COMUNICATIVO - BOA FLUENCIA VERBAL - DESEJAVEL EXPERIENCIA EM VENDAS, PRINCIPALMENTE NA AREA DE SEGURO PARA AUTOS OU PROTECAO VEICULAR - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, VENDEDOR, MASCULINO - ENSINO MEDIO COMPLETO - EXPERIENCIA NA AREA DE VENDAS DE MATERIAL DE CONSTRUCAO E ELETRICA, COM PELO MENOS 3 ANOS EM CTPS OU COMPROVADA POR EX EMPREGADOR - PONTUAL - COMPROMETIDO - PRO ATIVO - DINAMICO - COMUNICATIVO - PREFERENCIA POR CANDIDATOS QUE MOREM PROXIMO DO BAIRRO CIDADE PRAIANA]
[1, VENDEDOR, MASCULINO - MAIOR DE 18 ANOS - ENSINO MEDIO (PODENDO SER INCOMPLETO) - EXPERIENCIAS NA FUNCAO - COMPROMETIDO - PONTUAL - NAO FUMANTE (TRABALHO ENVOLVE INFLAMAVEIS) - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, VENDEDOR, SEXO MASCULINO - DE 30 A 45 ANOS - SEGUNDO GRAU COMPLETO - NAO FUMANTE -  CARTEIRA DE HABILITAÇAO B - NOÇOES DE INFORMATICA  - BOA FLUENCIA VERBAL - BOM RELACIONAMENTO INTERPESSOAL COM COLEGAS DE TRABALHO E CLIENTES - PONTUAL - SOMENTE MORADOR DE RIO DAS OSTRAS. APRESENTAR CURRICULO IMPRESSO ]
[1, VENDEDOR, VENDEDOR INTERNO (PARA MACAE) - MASCULINO E FEMININO - MORADORES DE RIO DAS OSTRAS - HABILIDADE EM COMUNICAÇAO - BOA FLUENCIA VERBAL - EXPERIENCIA COM VENDAS DE CURSOS - ENSINO MEDIO COMPLETO - DESEJAVEL SUPERIO COMPLETO OU ESTAR CURSANDO ADMINISTRAÇAO, PUBLICIDADE E PROPAGANDA OU JORNALISMO]
[9, VENDEDOR CORPORATIVO, MASCULINO E FEMININO - MAIOR DE 18 ANOS - ENSINO MEDIO COMPLETO - BOA FLUENCIA VERBAL - COMUNICATIVO - PONTUAL - COMPROMETIDO - AMBICIOSO - FOCADO - SOMENTE MORADOR DE RIO DAS OSTRAS
ATRIBUICOES: VENDAS PORTA A PORTA DE PRODUTOS DA VIVO, COMO: CELULAR, TV, INTERNET E TELEFONE FIXO.]
[1, VENDEDOR DE EMPRESTIMO CONSIGNADO, FEMININO - ACIMA DE 18 ANOS - ENSINO MEDIO COMPLETO - EXPERIENCIA DE PELO MENOS 6 MESES NA AREA ]
[2, VENDEDOR EXTERNO, MASCULINO E FEMININO - DE 23 A 55 ANOS - ENSINO MEDIO COMPLETO - COMUNICATIVO - BOA FLUENCIA VERBAL - EDUCADO - COMPROMETIDO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[1, VENDEDOR EXTERNO, MASCULINO E FEMININO - DE 25 A 40 ANOS - ENSINO MEDIO COMPLETO - HABILITACAO A/B - EXPERIENCIA EM MATERIAL DE CONSTRUCAO, VIDRACARIA OU SERRALHERIA - DESEJAVEL EXPERIENCIA EM CONTAS, CALCULOS E MEDIDAS - BOA FLUENCIA VERBAL E ESCRITA - NAO FUMANTE]
[10, VENDEDOR EXTERNO, MASCULINO E FEMININO - MAIOR DE 18 ANOS - ENSINO MEDIO (PODENDO SER INCOMPLETO) - IMPORTANTE TER CELULAR COM INTERNET - EXPERIENCIA DE PELO MENOS 6 MESES COM VENDAS -  COMPROMETIDO - AMBICIOSO - SOMENTE MORADOR DE RIO DAS OSTRAS]
[10, VENDEDOR INTERNO, MASCULINO E FEMININO - DE 20 A 50 ANOS - ENSINO MEDIO COMPLETO - NECESSARIO EXPERIENCIA EM VENDAS DE EMPRESTIMOS E CONSIGNADOS - COMPROMETIDO - PROATIVO - DETERMINADO - AMBICIOSO - SOMENTE MORADOR DE RIO DAS OSTRAS
* O SALARIO COMECARA A SER PAGO APOS DOIS MESES DE EXPERIENCIA, DURANTE ESSE PERIODO APENAS COMISSOES. POREM, CASO O EFETIVADO ATINJA A META ESTABELECIDA JA RECEBERA SALARIO MAIS COMISSOES, DESDE O INCIO.]
[1, VENDEDOR INTERNO, MASCULINO E FEMININO - MAIOR DE 18 ANOS - ENSINO MEDIO COMPLETO (OU EM CURSO) - EXPERIENCIA NAS ROTINAS ADMINISTRATIVAS E EM EMPRESTIMOS CONSIGNADOS]
PS C:\MyDartProjects\fluent_query_builder> 
ascii
PS C:\MyDartProjects\fluent_query_builder> dart run .\example\main2.dart
connection.settings: [[UTF8]]
connection.settings: {client_encoding: UTF8, DateStyle: ISO, MDY, integer_datetimes: on, is_superuser: off, server_encoding: SQL_ASCII, server_version: 8.1.19, session_authorization: sisadmin, standard_conforming_strings: off, TimeZone: UTC}
Unhandled exception:
FormatException: Invalid value in input: 186
#0      _UnicodeSubsetDecoder.convert (dart:convert/ascii.dart:178:11)
#1      AsciiCodec.decode (dart:convert/ascii.dart:55:54)
#2      PostgresBinaryDecoder.convert (package:postgres/src/binary_codec.dart:418:25)
#3      Query.addRow.<anonymous closure> (package:postgres/src/query.dart:149:12)
#4      MappedListIterable.elementAt (dart:_internal/iterable.dart:411:31)
#5      ListIterator.moveNext (dart:_internal/iterable.dart:340:26)
#6      new _GrowableList._ofEfficientLengthIterable (dart:core-patch/growable_array.dart:188:27)
#7      new _GrowableList.of (dart:core-patch/growable_array.dart:150:28)
#8      new List.of (dart:core-patch/array_patch.dart:50:28)
#9      ListIterable.toList (dart:_internal/iterable.dart:211:44)
#10     Query.addRow (package:postgres/src/query.dart:152:30)
#11     _PostgreSQLConnectionStateBusy.onMessage (package:postgres/src/connection_fsm.dart:297:13)
#12     PostgreSQLConnection._readData (package:postgres/src/connection.dart:293:47)
#13     _RootZone.runUnaryGuarded (dart:async/zone.dart:1546:10)
#14     _BufferingStreamSubscription._sendData (dart:async/stream_impl.dart:341:11)
#15     _BufferingStreamSubscription._add (dart:async/stream_impl.dart:271:7)
#16     _SyncStreamControllerDispatch._sendData (dart:async/stream_controller.dart:733:19)
#17     _StreamController._add (dart:async/stream_controller.dart:607:7)
#18     _StreamController.add (dart:async/stream_controller.dart:554:5)
#19     _Socket._onData (dart:io-patch/socket_patch.dart:2144:41)
#20     _RootZone.runUnaryGuarded (dart:async/zone.dart:1546:10)
#21     _BufferingStreamSubscription._sendData (dart:async/stream_impl.dart:341:11)
#22     _BufferingStreamSubscription._add (dart:async/stream_impl.dart:271:7)
#23     _SyncStreamControllerDispatch._sendData (dart:async/stream_controller.dart:733:19)
#24     _StreamController._add (dart:async/stream_controller.dart:607:7)
#25     _StreamController.add (dart:async/stream_controller.dart:554:5)
#26     new _RawSocket.<anonymous closure> (dart:io-patch/socket_patch.dart:1680:33)
#27     _NativeSocket.issueReadEvent.issue (dart:io-patch/socket_patch.dart:1192:14)
#28     _microtaskLoop (dart:async/schedule_microtask.dart:40:21)
#29     _startMicrotaskLoop (dart:async/schedule_microtask.dart:49:5)
#30     _runPendingImmediateCallback (dart:isolate-patch/isolate_patch.dart:120:13)
#31     _RawReceivePortImpl._handleMessage (dart:isolate-patch/isolate_patch.dart:185:5)
PS C:\MyDartProjects\fluent_query_builder> 
import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:convert/convert.dart';

void main(List<String> args) async {
  var connection = PostgreSQLConnection('192.168.66.5', 5432, 'sistemas',
      encoding: latin1, username: 'sisadmin', password: 's1sadm1n');

  await connection.open();
  // await connection.execute("SET CLIENT_ENCODING TO 'UTF8';");
  // await connection.query("SET NAMES  'UTF8';");
  print(
      "connection.settings: ${await connection.query('SHOW client_encoding;')}");

  print('connection.settings: ${connection.settings}');
  var query = '''
    SELECT SUM
	( a1.nr_vaga - a1.nr_vagaefetiv ) AS qtd,
	a3.nm_cargo,
	a1.nm_exigencia 
FROM
	sibem.tb_emprcargo a1,
	sibem.tb_empregador a2,
	sibem.tb_cargo a3 
WHERE
	a1.dt_encerra ISNULL 
	AND ( a1.nr_vaga - a1.nr_vagaefetiv ) > 0 
	AND a1.cd_empregador = a2.cd_empregador 
	AND a1.cd_cargo = a3.cd_cargo 
GROUP BY
	a3.nm_cargo,
	a1.nm_exigencia 
ORDER BY
	a3.nm_cargo
    ''';
  List<List<dynamic>> results = await connection.query(query);
  print('connection.settings: ${connection.settings}');

  for (final row in results) {
    print(row);
  }
  exit(0);
}

pubspec.yaml
name: example
description: 
version: 1.0.0
homepage: 
authors: 
  - Isaque Neves <insinfo2008@gmail.com> 
publish_to: none

environment:
  sdk: '>=2.12.0 <3.0.0'

dependencies:  
  #galileo_postgres: ^3.0.0
  #postgres: ^2.4.3
  convert: ^3.0.1
  postgres:
    git:
      url: https://github.com/isoos/postgresql-dart.git
      ref: encoding

  fluent_query_builder: 
    path: ../

dev_dependencies:
  pedantic: ^1.8.0
  test: ^1.6.0
pub upgrade
example> pub upgrade
Resolving dependencies...
  _fe_analyzer_shared 26.0.0 (34.0.0 available)
  analyzer 2.3.0 (3.2.0 available)
  args 2.3.0
  async 2.8.2
  boolean_selector 2.1.0
  buffer 1.1.1
  charcode 1.3.1
  cli_util 0.3.5
  collection 1.15.0
  convert 3.0.1
  coverage 1.0.3 (1.1.0 available)
  crypto 3.0.1
  file 6.1.2
  fluent_query_builder 3.0.1 from path ..
  frontend_server_client 2.1.2
  galileo_mysql 3.0.0
  galileo_postgres 3.0.0
  galileo_sqljocky5 3.0.0
  galileo_typed_buffer 3.0.0
  glob 2.0.1 (2.0.2 available)
  http_multi_server 3.0.1
  http_parser 4.0.0
  io 1.0.3
  js 0.6.3 (0.6.4 available)
  logging 1.0.2
  matcher 0.12.11
  meta 1.7.0
  mime 1.0.1
  node_preamble 2.0.1
  package_config 2.0.2
  path 1.8.1
  pedantic 1.11.1 (discontinued replaced by lints)
  pool 1.5.0
  postgres 2.4.3 from git https://github.com/isoos/postgresql-dart.git at 93f1ff
  pub_semver 2.1.0
  sasl_scram 0.1.0
  saslprep 1.0.2
  shelf 1.2.0
  shelf_packages_handler 3.0.0
  shelf_static 1.1.0
  shelf_web_socket 1.0.1
  source_map_stack_trace 2.1.0
  source_maps 0.10.10
  source_span 1.8.1 (1.8.2 available)
  stack_trace 1.10.0
  stream_channel 2.1.0
  string_scanner 1.1.0
  synchronized 3.0.0
  term_glyph 1.2.0
  test 1.17.12 (1.20.1 available)
  test_api 0.4.3 (0.4.9 available)
  test_core 0.4.2 (0.4.11 available)
  typed_data 1.3.0
  unorm_dart 0.2.0
  vm_service 7.5.0 (8.1.0 available)
  watcher 1.0.0 (1.0.1 available)
  web_socket_channel 2.1.0
  webkit_inspection_protocol 1.0.0
  yaml 3.1.0
No dependencies changed.
11 packages have newer versions incompatible with dependency constraints.
Try `dart pub outdated` for more information.
isoos
isoos commented on Feb 3, 2022
isoos
on Feb 3, 2022
Owner
@insinfo Thanks for the verification! I'll check and see how we should update the code, possibly in the next few days.

isoos
isoos commented on Feb 4, 2022
isoos
on Feb 4, 2022
Owner
@insinfo: I've updated the code in the branch, could you take another look, and also test it again, ideally with both inserts and selects with latin1 characters?

isoos
isoos commented on Feb 18, 2022
isoos
on Feb 18, 2022
Owner
/ping @insinfo any update? I would like to have some feedback on this before merging it into the mainline...

insinfo
insinfo commented on Feb 24, 2022
insinfo
on Feb 24, 2022 · edited by insinfo
Author
Sorry for the delay in responding but I've been very busy.
I did the test and the select is working well, but the Insert, Update and Delete do not.

Invalid byte sequence for "UTF8" encoding: 0xe36f20 Hint: This error can also happen if the byte sequence does not match the encoding expected by the server, which is controlled by "client_encoding".

import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:convert/convert.dart';

void main(List<String> args) async {
  var connection = PostgreSQLConnection('192.168.66.5', 5432, 'sistemas',
      encoding: latin1, username: 'sisadmin', password: 's1sadm1n');

  await connection.open();

  var query = '''
    SELECT SUM
	( a1.nr_vaga - a1.nr_vagaefetiv ) AS qtd,
	a3.nm_cargo,
	a1.nm_exigencia 
FROM
	sibem.tb_emprcargo a1,
	sibem.tb_empregador a2,
	sibem.tb_cargo a3 
WHERE
	a1.dt_encerra ISNULL 
	AND ( a1.nr_vaga - a1.nr_vagaefetiv ) > 0 
	AND a1.cd_empregador = a2.cd_empregador 
	AND a1.cd_cargo = a3.cd_cargo 
GROUP BY
	a3.nm_cargo,
	a1.nm_exigencia 
ORDER BY
	a3.nm_cargo
    ''';
  List<List<dynamic>> results = await connection.query(query);

  /* for (final row in results) {
    print(row);
  }*/

  /*var r = await connection.query(
      'INSERT INTO teste_is.test (name,phone) VALUES (@name,@phone);',
      substitutionValues: {
        'name': 'João Câmara',
        'phone': '5465454564',
      });
      print('insert: $r');*/

  /*var r2 = await connection.query(
      'UPDATE teste_is.test SET name=@name WHERE id=1',
      substitutionValues: {
        'name': 'João Câmara',
      });
  print('insert: $r2');*/

  var r3 = await connection
      .query('DELETE FROM teste_is.test WHERE name=@name', substitutionValues: {
    'name': 'João Câmara',
  });
  print('insert: $r3');
  exit(0);
}
PS C:\MyDartProjects\fluent_query_builder> dart .\example\main2.dart
connection.settings: [[UTF8]]
Unhandled exception:
PostgreSQLSeverity.unknown 22021: sequÃªncia de bytes invÃ¡lida para codificaÃ§Ã£o "UTF8": 0xe36f20 Hint: Este erro pode acontecer tambÃ©m se a sequÃªncia de bytes nÃ£o corresponde a codificaÃ§Ã£o esperado pelo servidor, que Ã© controlada por "client_encoding".
#0      _PostgreSQLExecutionContextMixin._query (package:postgres/src/connection.dart:460:18)
#1      _PostgreSQLExecutionContextMixin.query (package:postgres/src/connection.dart:433:7)
#2      main (file:///C:/MyDartProjects/fluent_query_builder/example/main2.dart:58:8)
<asynchronous suspension>
 postgres:
    git:
      url: https://github.com/isoos/postgresql-dart.git
      ref: encoding
insinfo
Add a comment
new Comment
Markdown input: edit mode selected.
Write
Preview
Use Markdown to format your comment
Metadata
Assignees
No one assigned
Labels
No labels
Projects
No projects
Milestone
No milestone
Relationships
None yet
Development
No branches or pull requests
NotificationsCustomize
You're receiving notifications because you're subscribed to this thread.

Participants
@isoos
@insinfo
Issue actions
Footer
© 2025 GitHub, Inc.
Footer navigation
Terms
Privacy
Security
Status
Community
Docs
Contact
Manage cookies
Do not share my personal information
not working with iso_8859_1 data · Issue #25 · isoos/postgresql-dart

Skip to content
Navigation Menu
dart-lang
sdk

Type / to search
Code
Issues
5k+
Pull requests
4
Actions
Projects
2
Wiki
Security
6
Insights
DateTime implementation on linux, dates before year 2020 return incorrect timezone #56312
Open
Open
DateTime implementation on linux, dates before year 2020 return incorrect timezone
#56312
@insinfo
Description
insinfo
opened on Jul 24, 2024 · edited by insinfo
I'm facing a problem, when I define a date as year: 2000, day: 1, month: 1, hour: 0, minute: 0, millisecond: 0 and microsecond: 0, in windows with timezone America / Sao Paulo when I convert it to string I receive the correct value "2000-01-01 00:00:00.000 -3", but in linux with timezone America / Sao Paulo I receive "2000-01-01 00:00:00.000 -2" it is bringing with timestamp -2 which is incorrect, it was supposed to receive -3 too, this is causing a problem in a postgresql driver implementation that receives for example the value microseconds 774702600000000 which is the local time "2024-07-19 11:10:00" from the postgresql driver and when I convert it to DateTime in dart gets wrong with one hour difference on linux.

void main(List<String> args) async {
  //774702600000000 = 2024-07-19 11:10:00 = DateTime(2024, 07, 19, 11, 10, 00)
  final dur = Duration(microseconds: 774702600000000);
  print('Duration $dur ${dur.inDays}');
  final dtUtc = DateTime.utc(2000).add(dur);

  final dtLocalDecode = DateTime(2000).add(dur);
  final dtLocal = dtUtc.toLocal();
  final dartDt = DateTime(2000, 1, 1, 0, 0, 0, 0, 0);
  final dartNow = DateTime.now();
  print('dtUtc $dtUtc ${dtUtc.timeZoneOffset}  ${dtUtc.timeZoneName}');
  print(
      'dtLocal utcToLocal $dtLocal ${dtLocal.timeZoneOffset}  ${dtLocal.timeZoneName}');
  print(
      'dtLocal decode $dtLocalDecode ${dtLocalDecode.timeZoneOffset}  ${dtLocalDecode.timeZoneName}');
  print('dartDt  $dartDt ${dartDt.timeZoneOffset}  ${dartDt.timeZoneName}');
  print('dartNow  $dartNow ${dartNow.timeZoneOffset}  ${dartNow.timeZoneName}');  
}
result in Windows 11
Duration 215195:10:00.000000 8966
dtUtc 2024-07-19 11:10:00.000Z 0:00:00.000000  UTC
dtLocal utcToLocal 2024-07-19 08:10:00.000 -3:00:00.000000  Hora oficial do Brasil
dtLocal decode 2024-07-19 11:10:00.000 -3:00:00.000000  Hora oficial do Brasil
dartDt  2000-01-01 00:00:00.000 -3:00:00.000000  Hora oficial do Brasil
dartNow  2024-07-24 15:54:01.433210 -3:00:00.000000  Hora oficial do Brasil
result in Ubuntu 22.04.2 LTS
Duration 215195:10:00.000000 8966
dtUtc 2024-07-19 11:10:00.000Z 0:00:00.000000  UTC
dtLocal utcToLocal 2024-07-19 08:10:00.000 -3:00:00.000000  -03
dtLocal decode 2024-07-19 10:10:00.000 -3:00:00.000000  -03
dartDt  2000-01-01 00:00:00.000 -2:00:00.000000  -02
dartNow  2024-07-24 15:53:50.647503 -3:00:00.000000  -03
Note that dtLocal decode on Windows displays 11 hours and on Linux 10 hours.

Also note that dartDt on Windows displays timezone -3 and on Linux -2.

Activity
dart-github-bot
dart-github-bot commented on Jul 24, 2024
dart-github-bot
on Jul 24, 2024
Collaborator
Summary: The DateTime implementation on Linux incorrectly handles time zones for dates before 2020, resulting in an off-by-one-hour discrepancy when converting from UTC to local time. This issue affects the DateTime constructor and toLocal() method, leading to incorrect time zone offsets for dates in the past.


dart-github-bot
added 
area-vm
Use area-vm for VM related issues, including code coverage, and the AOT and JIT backends.
 
triage-automation
See https://github.com/dart-lang/ecosystem/tree/main/pkgs/sdk_triage_bot.
 
type-bug
Incorrect behavior (everything from a crash to more subtle misbehavior)
 on Jul 24, 2024
MacielAzevedo
MacielAzevedo commented on Jul 24, 2024
MacielAzevedo
on Jul 24, 2024
I have the same problem, I've looked on several sites and haven't found any solution.

leonardomw
leonardomw commented on Jul 24, 2024
leonardomw
on Jul 24, 2024 · edited by leonardomw
I'm also having this problem and I didn't find anything in the documentation that differentiates DateTime on Linux from Windows.

insinfo
insinfo commented on Jul 24, 2024
insinfo
on Jul 24, 2024
Author
from what I saw this problem also happens in Debian GNU/Linux 10, from what I can find out it seems that in Linux the DateTime implementation is taking an old timezone transition and not the current TimeZone different from the Windows implementation


a-siva
added 
P2
A bug or feature request we're likely to work on
 
triaged
Issue has been triaged by sub team
 on Jul 24, 2024

a-siva
self-assigned thison Jul 24, 2024
lrhn
lrhn commented on Jul 25, 2024
lrhn
on Jul 25, 2024 · edited by lrhn
Member
If time-zone information differs between Windows and Linux, the difference is likely in the operating systems. Windows is known for not having all older time-zone information available in some time zones. I don't know if that's the case here.


lrhn
added 
library-core
 and removed 
triage-automation
See https://github.com/dart-lang/ecosystem/tree/main/pkgs/sdk_triage_bot.
 on Jul 25, 2024
MacielAzevedo
MacielAzevedo commented on Jul 25, 2024
MacielAzevedo
on Jul 25, 2024
How to create a DateTime instance in Dart using the current timezone in Linux so that the behavior is similar to what happens in Windows.

maciel-neto
maciel-neto commented on Jul 25, 2024
maciel-neto
on Jul 25, 2024
How to create a DateTime instance in Dart using the current timezone in Linux so that the behavior is similar to what happens in Windows.

insinfo
insinfo commented on Jul 25, 2024
insinfo
on Jul 25, 2024 · edited by insinfo
Author
@lrhn In Java the behavior is identical in both Windows and Linux, see that dtLocal decode displays as 11:10 on windows and linux, which was the behavior I expected for dart

public class Main {
    public static void main(String[] args) {
        // 774702600000000 microseconds = 2024-07-19 11:10:00
        Duration duration = Duration.of(774702600000000L, ChronoUnit.MICROS);
        System.out.println("Duration " + duration + " " + duration.toDays());

        ZonedDateTime dtUtc = ZonedDateTime.of(LocalDateTime.of(2000, 1, 1, 0, 0), ZoneId.of("UTC")).plus(duration);
        LocalDateTime dtLocalDecode = LocalDateTime.of(2000, 1, 1, 0, 0).plus(duration);
        ZonedDateTime dtLocal = dtUtc.withZoneSameInstant(ZoneId.systemDefault());
        LocalDateTime dartDt = LocalDateTime.of(2000, 1, 1, 0, 0);
        LocalDateTime dartNow = LocalDateTime.now();

        System.out.println("dtUtc " + dtUtc + " " + dtUtc.getOffset() + "  " + dtUtc.getZone());
        System.out.println("dtLocal utcToLocal " + dtLocal + " " + dtLocal.getOffset() + "  " + dtLocal.getZone());
        System.out.println("dtLocal decode " + dtLocalDecode + " " + ZoneId.systemDefault().getRules().getOffset(dtLocalDecode) + "  " + ZoneId.systemDefault());
        System.out.println("dartDt  " + dartDt + " " + ZoneId.systemDefault().getRules().getOffset(dartDt) + "  " + ZoneId.systemDefault());
        System.out.println("dartNow  " + dartNow + " " + ZoneId.systemDefault().getRules().getOffset(dartNow) + "  " + ZoneId.systemDefault());
    }
}
windows
Microsoft Windows 11 Pro 10.0.22631 64 bits
javac Main.java; java Main
Duration PT215195H10M 8966
dtUtc 2024-07-19T11:10Z[UTC] Z  UTC
dtLocal utcToLocal 2024-07-19T08:10-03:00[America/Sao_Paulo] -03:00  America/Sao_Paulo
dtLocal decode 2024-07-19T11:10 -03:00  America/Sao_Paulo
dartDt  2000-01-01T00:00 -02:00  America/Sao_Paulo
dartNow  2024-07-25T15:52:53.860442900 -03:00  America/Sao_Paulo
linux
Ubuntu 22.04.2 LTS
 javac Main.java; java Main
Duration PT215195H10M 8966
dtUtc 2024-07-19T11:10Z[UTC] Z  UTC
dtLocal utcToLocal 2024-07-19T08:10-03:00[America/Sao_Paulo] -03:00  America/Sao_Paulo
dtLocal decode 2024-07-19T11:10 -03:00  America/Sao_Paulo
dartDt  2000-01-01T00:00 -02:00  America/Sao_Paulo
dartNow  2024-07-25T15:52:59.152457 -03:00  America/Sao_Paulo
insinfo
insinfo commented on Jul 25, 2024
insinfo
on Jul 25, 2024 · edited by insinfo
Author
In C# the behavior is also identical on Windows and Linux, in both the dtLocal decode is 11:10

class Program
{
    static void Main(string[] args)
    {
        // 774702600000000 microseconds = 2024-07-19 11:10:00 = DateTime(2024, 07, 19, 11, 10, 00)
        TimeSpan dur = TimeSpan.FromTicks(774702600000000 * 10); // Convert microseconds to ticks 
        Console.WriteLine($"Duration {dur} {dur.Days}");
        
        DateTime dtUtc = new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc).Add(dur);
        DateTime dtLocalDecode = new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Local).Add(dur);
        DateTime dtLocal = dtUtc.ToLocalTime();
        DateTime dartDt = new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Local);
        DateTime dartNow = DateTime.Now;

        Console.WriteLine($"dtUtc {dtUtc}  {dtUtc.Kind}");
        Console.WriteLine($"dtLocal utcToLocal {dtLocal}   {dtLocal.Kind}");
        Console.WriteLine($"dtLocal decode {dtLocalDecode}  {dtLocalDecode.Kind}");
        Console.WriteLine($"dartDt  {dartDt}   {dartDt.Kind}");
        Console.WriteLine($"dartNow  {dartNow}   {dartNow.Kind}");
    }
}
windows
dotnet run
Duration 8966.11:10:00 8966
dtUtc 19/07/2024 11:10:00  Utc
dtLocal utcToLocal 19/07/2024 08:10:00   Local
dtLocal decode 19/07/2024 11:10:00  Local
dartDt  01/01/2000 00:00:00   Local
dartNow  25/07/2024 16:17:19   Local
linux
 dotnet run
Duration 8966.11:10:00 8966
dtUtc 19/07/2024 11:10:00  Utc
dtLocal utcToLocal 19/07/2024 08:10:00   Local
dtLocal decode 19/07/2024 11:10:00  Local
dartDt  01/01/2000 00:00:00   Local
dartNow  25/07/2024 16:18:55   Local
insinfo
insinfo commented on Jul 25, 2024
insinfo
on Jul 25, 2024 · edited by insinfo
Author
@lrhn My use case is in this PostgreSQL driver, when decoding data of type timestamp without timezone and type date, since they are not UTC. For these fields, you want the value sent to be returned from the db in an identical form without alteration. In most cases, they will be local using the same timezone as the current server where PostgreSQL runs and runs the backend application to do comparisons and operations with DateTime.now().

    case PostgreSQLDataType.date:
        final value = buffer.getInt32(0);
        //infinity || -infinity
        if (value == 2147483647 || value == -2147483648) {
          return null;
        }
        if (timeZone.forceDecodeDateAsUTC) {
          return DateTime.utc(2000).add(Duration(days: value)) as T;
        }

        // https://github.com/dart-lang/sdk/issues/56312
        // ignore past timestamp transitions and use only current timestamp in local datetime        
        final nowDt = DateTime.now();
        var baseDt = DateTime(2000);
        if (baseDt.timeZoneOffset != nowDt.timeZoneOffset) {
          final difference = baseDt.timeZoneOffset - nowDt.timeZoneOffset;
          baseDt = baseDt.add(difference);
        }
        return baseDt.add(Duration(days: value)) as T;

      case PostgreSQLDataType.timestampWithoutTimezone:
        final value = buffer.getInt64(0);
        //infinity || -infinity
        if (value == 9223372036854775807 || value == -9223372036854775808) {
          return null;
        }
        if (timeZone.forceDecodeTimestampAsUTC) {
          return DateTime.utc(2000).add(Duration(microseconds: value)) as T;
        }

        // https://github.com/dart-lang/sdk/issues/56312
        // ignore previous timestamp transitions and use only the current system timestamp in local date and time so that the behavior is correct on Windows and Linux
        final nowDt = DateTime.now();
        var baseDt = DateTime(2000);
        if (baseDt.timeZoneOffset != nowDt.timeZoneOffset) {
          final difference = baseDt.timeZoneOffset - nowDt.timeZoneOffset;
          baseDt = baseDt.add(difference);
        }
        return baseDt.add(Duration(microseconds: value)) as T;

      case PostgreSQLDataType.timestampWithTimezone:
        final value = buffer.getInt64(0);

        //infinity || -infinity
        if (value == 9223372036854775807 || value == -9223372036854775808) {
          return null;
        }
       
        var datetime = DateTime.utc(2000).add(Duration(microseconds: value));
        if (timeZone.forceDecodeTimestamptzAsUTC) {
          return datetime as T;
        }
        if (timeZone.value.toLowerCase() == 'utc') {
          return datetime as T;
        }

        final pgTimeZone = timeZone.value.toLowerCase();
        final tzLocations = tz.timeZoneDatabase.locations.entries
            .where((e) {
              return (e.key.toLowerCase() == pgTimeZone ||
                  e.value.currentTimeZone.abbreviation.toLowerCase() ==
                      pgTimeZone);
            })
            .map((e) => e.value)
            .toList();

        if (tzLocations.isEmpty) {
          throw tz.LocationNotFoundException(
              'Location with the name "$pgTimeZone" doesn\'t exist');
        }
        final tzLocation = tzLocations.first;
        //define location for TZDateTime.toLocal()
        tzenv.setLocalLocation(tzLocation);

        final offsetInMilliseconds = tzLocation.currentTimeZone.offset;
        // Conversion of milliseconds to hours
        final double offset = offsetInMilliseconds / (1000 * 60 * 60);

        if (offset < 0) {
          final subtr = Duration(
              hours: offset.abs().truncate(),
              minutes: ((offset.abs() % 1) * 60).round());
          datetime = datetime.subtract(subtr);
          final specificDate = tz.TZDateTime(
              tzLocation,
              datetime.year,
              datetime.month,
              datetime.day,
              datetime.hour,
              datetime.minute,
              datetime.second,
              datetime.millisecond,
              datetime.microsecond);
          return specificDate as T;
        } else if (offset > 0) {
          final addr = Duration(
              hours: offset.truncate(), minutes: ((offset % 1) * 60).round());
          datetime = datetime.add(addr);
          final specificDate = tz.TZDateTime(
              tzLocation,
              datetime.year,
              datetime.month,
              datetime.day,
              datetime.hour,
              datetime.minute,
              datetime.second,
              datetime.millisecond,
              datetime.microsecond);
          return specificDate as T;
        }

        return datetime as T;
https://github.com/insinfo/postgres_fork/blob/master/lib/src/binary_codec.dart

insinfo
Add a comment
new Comment
Markdown input: edit mode selected.
Write
Preview
Use Markdown to format your comment
Remember, contributions to this repository should follow its contributing guidelines, security policy and code of conduct.
Metadata
Assignees
Labels
P2
A bug or feature request we're likely to work on
area-vm
Use area-vm for VM related issues, including code coverage, and the AOT and JIT backends.
library-core
triaged
Issue has been triaged by sub team
type-bug
Incorrect behavior (everything from a crash to more subtle misbehavior)
Type
No type
Projects
No projects
Milestone
No milestone
Relationships
None yet
Development
No branches or pull requests
NotificationsCustomize
You're receiving notifications because you're subscribed to this thread.

Participants
@lrhn
@leonardomw
@a-siva
@insinfo
@MacielAzevedo
Issue actions
Footer
© 2025 GitHub, Inc.
Footer navigation
Terms
Privacy
Security
Status
Community
Docs
Contact
Manage cookies
Do not share my personal information
DateTime implementation on linux, dates before year 2020 return incorrect timezone · Issue #56312 · dart-lang/sdk