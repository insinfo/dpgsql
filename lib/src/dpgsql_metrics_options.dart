/// Options to configure dpgsql metrics.
/// TODO
/// Mirrors NpgsqlMetricsOptions, which currently exists as an extension point
/// even when no options are required. Keeping this public type lets builders
/// and future observability code expose Npgsql-like signatures. 
class DpgsqlMetricsOptions {
  const DpgsqlMetricsOptions();
}
