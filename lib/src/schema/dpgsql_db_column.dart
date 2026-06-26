import '../dpgsql_db_type.dart';

/// Provides schema information about a column.
/// Porting DpgsqlDbColumn.cs
///
/// Note that this can correspond to a field returned in a query which isn't an actual table column.
class DpgsqlDbColumn {
  DpgsqlDbColumn() {
    // Not supported in PostgreSQL
    isExpression = false;
    isAliased = false;
    isHidden = false;
    isIdentity = false;
  }

  // Standard fields
  /// Whether the column allows null values.
  bool? allowDbNull;

  /// The catalog (database) name.
  String? baseCatalogName;

  /// The column name without alias.
  String? baseColumnName;

  /// The schema name.
  String? baseSchemaName;

  /// The server name.
  String? baseServerName;

  /// The table name.
  String? baseTableName;

  /// The column name (with alias if present).
  String? columnName;

  /// The zero-based ordinal position of the column in the result set.
  int? columnOrdinal;

  /// The maximum possible length of a value in the column (in bytes for binary, characters for text).
  int? columnSize;

  /// Whether the column is aliased.
  bool? isAliased;

  /// Whether the column is auto-incremented.
  bool? isAutoIncrement;

  /// Whether the column is an expression.
  bool? isExpression;

  /// Whether the column is hidden.
  bool? isHidden;

  /// Whether the column is an identity column.
  bool? isIdentity;

  /// Whether the column is a key column.
  bool? isKey;

  /// Whether the column contains long data (e.g., text, bytea).
  bool? isLong;

  /// Whether the column is read-only.
  bool? isReadOnly;

  /// Whether the column is unique.
  bool? isUnique;

  /// The numeric precision.
  int? numericPrecision;

  /// The numeric scale.
  int? numericScale;

  /// The UDT assembly qualified name (for user-defined types).
  String? udtAssemblyQualifiedName;

  /// The Dart type of the column.
  Type? dataType;

  /// The PostgreSQL type name.
  String? dataTypeName;

  // Dpgsql-specific fields

  /// The OID of the type of this column in the PostgreSQL pg_type catalog table.
  int? typeOid;

  /// The OID of the PostgreSQL table of this column.
  int? tableOid;

  /// The column's position within its table. Note that this is different from columnOrdinal,
  /// which is the column's position within the resultset.
  int? columnAttributeNumber;

  /// The default SQL expression for this column.
  String? defaultValue;

  /// The DpgsqlDbType value for this column's type.
  DpgsqlDbType? dpgsqlDbType;

  /// Clone this instance.
  DpgsqlDbColumn clone() {
    return DpgsqlDbColumn()
      ..allowDbNull = allowDbNull
      ..baseCatalogName = baseCatalogName
      ..baseColumnName = baseColumnName
      ..baseSchemaName = baseSchemaName
      ..baseServerName = baseServerName
      ..baseTableName = baseTableName
      ..columnName = columnName
      ..columnOrdinal = columnOrdinal
      ..columnSize = columnSize
      ..isAliased = isAliased
      ..isAutoIncrement = isAutoIncrement
      ..isExpression = isExpression
      ..isHidden = isHidden
      ..isIdentity = isIdentity
      ..isKey = isKey
      ..isLong = isLong
      ..isReadOnly = isReadOnly
      ..isUnique = isUnique
      ..numericPrecision = numericPrecision
      ..numericScale = numericScale
      ..udtAssemblyQualifiedName = udtAssemblyQualifiedName
      ..dataType = dataType
      ..dataTypeName = dataTypeName
      ..typeOid = typeOid
      ..tableOid = tableOid
      ..columnAttributeNumber = columnAttributeNumber
      ..defaultValue = defaultValue
      ..dpgsqlDbType = dpgsqlDbType;
  }

  @override
  String toString() {
    return 'DpgsqlDbColumn(columnName: $columnName, dataTypeName: $dataTypeName, '
        'allowDbNull: $allowDbNull, columnSize: $columnSize)';
  }

  /// Get a property by name.
  dynamic operator [](String propertyName) {
    switch (propertyName) {
      case 'AllowDbNull':
        return allowDbNull;
      case 'BaseColumnName':
        return baseColumnName;
      case 'BaseSchemaName':
        return baseSchemaName;
      case 'BaseTableName':
        return baseTableName;
      case 'ColumnName':
        return columnName;
      case 'ColumnOrdinal':
        return columnOrdinal;
      case 'ColumnSize':
        return columnSize;
      case 'DataType':
        return dataType;
      case 'DataTypeName':
        return dataTypeName;
      case 'IsAutoIncrement':
        return isAutoIncrement;
      case 'IsKey':
        return isKey;
      case 'IsUnique':
        return isUnique;
      case 'NumericPrecision':
        return numericPrecision;
      case 'NumericScale':
        return numericScale;
      case 'TypeOid':
        return typeOid;
      case 'TableOid':
        return tableOid;
      case 'ColumnAttributeNumber':
        return columnAttributeNumber;
      case 'DefaultValue':
        return defaultValue;
      case 'DpgsqlDbType':
        return dpgsqlDbType;
      default:
        return null;
    }
  }
}
