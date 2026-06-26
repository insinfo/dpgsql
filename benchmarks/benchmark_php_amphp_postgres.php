<?php

require __DIR__ . '/php_benchmark/vendor/autoload.php';

use Amp\Postgres\PostgresConfig;
use function Amp\Postgres\connect;

function env_or_default(string $key, string $fallback): string
{
    $value = getenv($key);
    if ($value === false) {
        return $fallback;
    }

    $value = trim($value);
    return $value === '' ? $fallback : $value;
}

function env_int(string $key, int $fallback): int
{
    $value = getenv($key);
    if ($value === false || trim($value) === '') {
        return $fallback;
    }

    $parsed = filter_var($value, FILTER_VALIDATE_INT);
    return $parsed === false || $parsed <= 0 ? $fallback : $parsed;
}

function env_bool(string $key, bool $fallback): bool
{
    $value = getenv($key);
    if ($value === false || trim($value) === '') {
        return $fallback;
    }

    return in_array(strtolower(trim($value)), ['1', 'true', 'yes', 'on'], true);
}

function checked_table_name(string $tableName): string
{
    if (!preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $tableName)) {
        throw new InvalidArgumentException('Invalid benchmark table name.');
    }

    return $tableName;
}

function amp_config(
    string $host,
    int $port,
    string $user,
    string $password,
    string $database,
    bool $secure
): PostgresConfig {
    return new PostgresConfig(
        $host,
        $port,
        $user,
        $password,
        $database,
        null,
        $secure ? 'require' : 'disable'
    );
}

function first_value(array $row)
{
    $values = array_values($row);
    return $values[0] ?? null;
}

function ensure_benchmark_rows($connection, int $targetRows, string $tableName): void
{
    $connection->query("
        CREATE TABLE IF NOT EXISTS $tableName (
            id INTEGER PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            amount NUMERIC(10, 2) NOT NULL,
            created_at TIMESTAMP NOT NULL,
            payload TEXT NOT NULL
        )
    ");

    $existingRows = 0;
    foreach ($connection->query("SELECT COUNT(*) AS count FROM $tableName") as $row) {
        $existingRows = (int)first_value($row);
    }
    if ($existingRows >= $targetRows) {
        return;
    }

    $connection->query("TRUNCATE TABLE $tableName");

    $batchSize = 500;
    for ($start = 1; $start <= $targetRows; $start += $batchSize) {
        $end = min($targetRows, $start + $batchSize - 1);
        $values = [];

        for ($id = $start; $id <= $end; $id++) {
            $cents = str_pad((string)($id % 100), 2, '0', STR_PAD_LEFT);
            $second = str_pad((string)($id % 60), 2, '0', STR_PAD_LEFT);
            $payloadId = str_pad((string)$id, 5, '0', STR_PAD_LEFT);
            $values[] = sprintf(
                "(%d,'name_%d',%d.%s,'2024-01-01 12:34:%s','payload_%s_abcdefghijklmnopqrstuvwxyz')",
                $id,
                $id,
                $id,
                $cents,
                $second,
                $payloadId
            );
        }

        $connection->query(
            "INSERT INTO $tableName (id, name, amount, created_at, payload) VALUES " . implode(',', $values)
        );
    }
}

final class BenchmarkTypedRow implements JsonSerializable
{
    public function __construct(
        public int $id,
        public string $name,
        public float $amount,
        public DateTimeImmutable $createdAt,
        public string $payload
    ) {
    }

    public function jsonSerialize(): array
    {
        return [
            'id' => $this->id,
            'name' => $this->name,
            'amount' => $this->amount,
            'created_at' => $this->createdAt->format('Y-m-d H:i:s'),
            'payload' => $this->payload,
        ];
    }
}

function benchmark_result_set(
    $connection,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        foreach ($connection->query($query) as $row) {
            $checksum += (int)$row['id']
                + strlen((string)$row['name'])
                + strlen((string)$row['amount'])
                + strlen((string)$row['created_at'])
                + strlen((string)$row['payload']);
        }
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        foreach ($connection->query($query) as $row) {
            $checksum += (int)$row['id']
                + strlen((string)$row['name'])
                + strlen((string)$row['amount'])
                + strlen((string)$row['created_at'])
                + strlen((string)$row['payload']);
            $rowCount++;
        }
    }
    $elapsedNs = hrtime(true) - $start;
    $elapsedSeconds = $elapsedNs / 1000000000;

    return [
        'rows_per_query' => $size,
        'iterations' => $iterations,
        'warmup_iterations' => $warmupIterations,
        'total_ms' => $elapsedNs / 1000000,
        'avg_ms' => ($elapsedNs / 1000000) / $iterations,
        'queries_per_sec' => $iterations / $elapsedSeconds,
        'rows_per_sec' => $rowCount / $elapsedSeconds,
        'checksum' => $checksum,
    ];
}

function benchmark_result_set_drain(
    $connection,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        foreach ($connection->query($query) as $_) {
            $checksum++;
        }
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        foreach ($connection->query($query) as $_) {
            $checksum++;
            $rowCount++;
        }
    }
    $elapsedNs = hrtime(true) - $start;
    $elapsedSeconds = $elapsedNs / 1000000000;

    return [
        'rows_per_query' => $size,
        'iterations' => $iterations,
        'warmup_iterations' => $warmupIterations,
        'total_ms' => $elapsedNs / 1000000,
        'avg_ms' => ($elapsedNs / 1000000) / $iterations,
        'queries_per_sec' => $iterations / $elapsedSeconds,
        'rows_per_sec' => $rowCount / $elapsedSeconds,
        'checksum' => $checksum,
    ];
}

function benchmark_result_set_simple(
    $connection,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        foreach ($connection->query($query) as $row) {
            $checksum += (int)$row['id'] + strlen((string)$row['name']) + strlen((string)$row['payload']);
        }
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        foreach ($connection->query($query) as $row) {
            $checksum += (int)$row['id'] + strlen((string)$row['name']) + strlen((string)$row['payload']);
            $rowCount++;
        }
    }
    $elapsedNs = hrtime(true) - $start;
    $elapsedSeconds = $elapsedNs / 1000000000;

    return [
        'rows_per_query' => $size,
        'iterations' => $iterations,
        'warmup_iterations' => $warmupIterations,
        'total_ms' => $elapsedNs / 1000000,
        'avg_ms' => ($elapsedNs / 1000000) / $iterations,
        'queries_per_sec' => $iterations / $elapsedSeconds,
        'rows_per_sec' => $rowCount / $elapsedSeconds,
        'checksum' => $checksum,
    ];
}

function benchmark_result_set_maps(
    $connection,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    return benchmark_result_set(
        $connection,
        $tableName,
        $size,
        $warmupIterations,
        $iterations
    );
}

function benchmark_application_typed_json(
    $connection,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        foreach ($connection->query($query) as $row) {
            $typed = new BenchmarkTypedRow(
                (int)$row['id'],
                (string)$row['name'],
                (float)$row['amount'],
                new DateTimeImmutable((string)$row['created_at']),
                (string)$row['payload']
            );
            $json = json_encode($typed, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
            $checksum += $typed->id + strlen($json);
        }
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        foreach ($connection->query($query) as $row) {
            $typed = new BenchmarkTypedRow(
                (int)$row['id'],
                (string)$row['name'],
                (float)$row['amount'],
                new DateTimeImmutable((string)$row['created_at']),
                (string)$row['payload']
            );
            $json = json_encode($typed, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
            $checksum += $typed->id + strlen($json);
            $rowCount++;
        }
    }
    $elapsedNs = hrtime(true) - $start;
    $elapsedSeconds = $elapsedNs / 1000000000;

    return [
        'rows_per_query' => $size,
        'iterations' => $iterations,
        'warmup_iterations' => $warmupIterations,
        'total_ms' => $elapsedNs / 1000000,
        'avg_ms' => ($elapsedNs / 1000000) / $iterations,
        'queries_per_sec' => $iterations / $elapsedSeconds,
        'rows_per_sec' => $rowCount / $elapsedSeconds,
        'checksum' => $checksum,
    ];
}

$host = env_or_default('PGHOST', env_or_default('POSTGRES_HOST', '127.0.0.1'));
$port = env_int('PGPORT', env_int('POSTGRES_PORT', 5432));
$user = env_or_default('PGUSER', env_or_default('POSTGRES_USER', 'dart'));
$password = env_or_default('PGPASSWORD', env_or_default('POSTGRES_PASSWORD', 'dart'));
$database = env_or_default('PGDATABASE', env_or_default('POSTGRES_DATABASE', 'dart_test'));
$benchTable = checked_table_name(env_or_default('BENCH_TABLE', 'bench_rows_php_amphp_postgres'));
$secure = env_bool('POSTGRES_SECURE', false);
$iterations = env_int('BENCH_ITERATIONS', 2000);
$connectIterations = env_int('BENCH_CONNECT_ITERATIONS', 25);
$warmupIterations = env_int('BENCH_WARMUP_ITERATIONS', 200);
$resultSetIterations = env_int('BENCH_RESULTSET_ITERATIONS', 20);
$resultSetWarmupIterations = env_int('BENCH_RESULTSET_WARMUP_ITERATIONS', 5);
$resultSetSizes = array_values(array_filter(array_map(
    fn($value) => (int)trim($value),
    explode(',', env_or_default('BENCH_RESULTSET_SIZES', '10,1000,3000,10000'))
), fn($value) => $value > 0));

$config = amp_config($host, $port, $user, $password, $database, $secure);
$connection = connect($config);

$server = [];
foreach ($connection->query("SELECT version() AS version, current_setting('server_version_num') AS server_version_num") as $row) {
    $server = [
        'version' => $row['version'],
        'server_version_num' => $row['server_version_num'],
    ];
}

$connectStart = hrtime(true);
for ($i = 0; $i < $connectIterations; $i++) {
    $connectConnection = connect($config);
    foreach ($connectConnection->query('SELECT 1') as $_) {
    }
    $connectConnection->close();
}
$connectElapsedNs = hrtime(true) - $connectStart;

ensure_benchmark_rows($connection, max($resultSetSizes), $benchTable);

$textChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    foreach ($connection->query('SELECT 1') as $row) {
        $textChecksum += (int)first_value($row);
    }
}

$textStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    foreach ($connection->query('SELECT 1') as $row) {
        $textChecksum += (int)first_value($row);
    }
}
$textElapsedNs = hrtime(true) - $textStart;

$parameterChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    foreach ($connection->execute('SELECT $1::int + $2::int', [40, 2]) as $row) {
        $parameterChecksum += (int)first_value($row);
    }
}

$parameterStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    foreach ($connection->execute('SELECT $1::int + $2::int', [40, 2]) as $row) {
        $parameterChecksum += (int)first_value($row);
    }
}
$parameterElapsedNs = hrtime(true) - $parameterStart;

$preparedStatement = $connection->prepare('SELECT $1::int + $2::int');
$preparedChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    foreach ($preparedStatement->execute([40, 2]) as $row) {
        $preparedChecksum += (int)first_value($row);
    }
}

$preparedStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    foreach ($preparedStatement->execute([40, 2]) as $row) {
        $preparedChecksum += (int)first_value($row);
    }
}
$preparedElapsedNs = hrtime(true) - $preparedStart;

$resultSets = [];
$resultSetsDrain = [];
$resultSetsSimple = [];
$resultSetsMaps = [];
$applicationTypedJson = [];
foreach ($resultSetSizes as $size) {
    $resultSetsDrain["rows_$size"] = benchmark_result_set_drain(
        $connection,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $resultSetsSimple["rows_$size"] = benchmark_result_set_simple(
        $connection,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $resultSetsMaps["rows_$size"] = benchmark_result_set_maps(
        $connection,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $applicationTypedJson["rows_$size"] = benchmark_application_typed_json(
        $connection,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $resultSets["rows_$size"] = benchmark_result_set(
        $connection,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
}

$connection->close();

$connectTotalMs = $connectElapsedNs / 1000000;
$textTotalMs = $textElapsedNs / 1000000;
$parameterTotalMs = $parameterElapsedNs / 1000000;
$preparedTotalMs = $preparedElapsedNs / 1000000;

echo json_encode([
    'driver' => env_or_default('BENCH_DRIVER_NAME', 'php_amphp_postgres'),
    'host' => $host,
    'port' => $port,
    'database' => $database,
    'secure' => $secure,
    'connect_mode' => 'warm_auth_cache',
    'server' => $server,
    'connect_iterations' => $connectIterations,
    'connect_total_ms' => $connectTotalMs,
    'connect_avg_ms' => $connectTotalMs / $connectIterations,
    'iterations' => $iterations,
    'warmup_iterations' => $warmupIterations,
    'resultset_warmup_iterations' => $resultSetWarmupIterations,
    'text_total_ms' => $textTotalMs,
    'text_avg_ms' => $textTotalMs / $iterations,
    'text_ops_per_sec' => $iterations / ($textElapsedNs / 1000000000),
    'text_checksum' => $textChecksum,
    'parameter_total_ms' => $parameterTotalMs,
    'parameter_avg_ms' => $parameterTotalMs / $iterations,
    'parameter_ops_per_sec' => $iterations / ($parameterElapsedNs / 1000000000),
    'parameter_checksum' => $parameterChecksum,
    'prepared_total_ms' => $preparedTotalMs,
    'prepared_avg_ms' => $preparedTotalMs / $iterations,
    'prepared_ops_per_sec' => $iterations / ($preparedElapsedNs / 1000000000),
    'prepared_checksum' => $preparedChecksum,
    'result_sets_drain' => $resultSetsDrain,
    'result_sets_simple' => $resultSetsSimple,
    'result_sets_maps' => $resultSetsMaps,
    'application_typed_json' => $applicationTypedJson,
    'result_sets' => $resultSets,
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), PHP_EOL;
