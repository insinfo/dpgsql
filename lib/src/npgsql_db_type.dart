/// Specifies the PostgreSQL data type of a parameter or column.
/// Porting NpgsqlDbType.cs
enum NpgsqlDbType {
  bigint,
  boolean,
  box,
  bytea,
  circle,
  char,
  date,
  double,
  integer,
  json,
  jsonb,
  line,
  lSeg,
  money,
  numeric,
  path,
  point,
  polygon,
  real,
  smallint,
  text,
  time,
  timestamp,
  timestampTz,
  uuid,
  varbit,
  varchar,
  xml,
  unknown,

  // Ranges
  integerRange,
  bigIntRange,
  numRange,
  tsRange,
  tsTzRange,
  dateRange,

  // Arrays (We might need a different approach for arrays if we don't use bit flags in Dart enums easily)
  // For now, let's assume we use a separate property isArray or just specific Array types if needed.
  // But Npgsql uses bitwise OR. Dart enums don't support that directly.
  // We can add specific array types or handle it in the parameter.
}
