/// Specifies the isolation level of a transaction.
enum IsolationLevel {
  /// The default isolation level.
  readCommitted,

  /// A dirty read is possible, meaning that no shared locks are issued and no exclusive locks are honored.
  readUncommitted,

  /// Shared locks are held until the transaction completes.
  repeatableRead,

  /// A range lock is placed on the DataSet, preventing other users from updating or inserting rows into the dataset until the transaction is complete.
  serializable,

  /// Reduces blocking by storing a version of data that one application can read while another is modifying the same data.
  snapshot,
}
