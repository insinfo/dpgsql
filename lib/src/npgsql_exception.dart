/// The exception that is thrown when the PostgreSQL backend reports an error.
/// Porting NpgsqlException.cs
class NpgsqlException implements Exception {
  NpgsqlException(this.message, [this.innerException]);

  final String message;
  final Object? innerException;

  @override
  String toString() {
    if (innerException == null) {
      return 'NpgsqlException: $message';
    }
    return 'NpgsqlException: $message\nInnerException: $innerException';
  }
}
