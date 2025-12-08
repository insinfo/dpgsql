/// Identifies the style of parameter placeholders in SQL.
enum PlaceholderIdentifier {
  /// PostgreSQL native style: $1, $2, $3, etc.
  /// Example: SELECT * FROM users WHERE id = $1
  numeric,

  /// Question mark style (PDO/MySQL compatible): ?, ?, ?, etc.
  /// Example: SELECT * FROM users WHERE id = ? AND name = ?
  onlyQuestionMark,

  /// Named parameters style: @param1, @param2, etc.
  /// Example: SELECT * FROM users WHERE id = @id
  atSign,
}
