/// The exception that is thrown when the PostgreSQL backend reports an error.
/// Porting DpgsqlException.cs
class DpgsqlException implements Exception {
  DpgsqlException(this.message, [this.innerException]);

  final String message;
  final Object? innerException;

  @override
  String toString() {
    if (innerException == null) {
      return 'DpgsqlException: $message';
    }
    return 'DpgsqlException: $message\nInnerException: $innerException';
  }
}
