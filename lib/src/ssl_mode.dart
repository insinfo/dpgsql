/// Specifies how to manage SSL.
enum SslMode {
  /// SSL is disabled. If the server requires SSL, the connection will fail.
  disable,

  /// Allow SSL.
  allow,

  /// Prefer SSL. If the server supports SSL, use it. If not, connect without SSL.
  prefer,

  /// Require SSL. If the server does not support SSL, the connection will fail.
  require,

  /// Require SSL and verify the server certificate CA.
  verifyCa,

  /// Require SSL and verify the server certificate CA and hostname.
  verifyFull
}
