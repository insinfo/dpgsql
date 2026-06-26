<?php

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

function pgsql_connect_bench(
    string $host,
    int $port,
    string $user,
    string $password,
    string $database,
    bool $secure
) {
    $sslMode = $secure ? 'require' : 'disable';
    $connString = sprintf(
        'host=%s port=%d dbname=%s user=%s password=%s sslmode=%s',
        $host,
        $port,
        $database,
        $user,
        $password,
        $sslMode
    );
    $connection = pg_connect($connString);
    if ($connection === false) {
        throw new RuntimeException('pg_connect failed');
    }
    return $connection;
}

function ensure_benchmark_rows($connection, int $targetRows, string $tableName): void
{
    pg_query($connection, "
        CREATE TABLE IF NOT EXISTS $tableName (
            id INTEGER PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            amount NUMERIC(10, 2) NOT NULL,
            created_at TIMESTAMP NOT NULL,
            payload TEXT NOT NULL
        )
    ");

    $result = pg_query($connection, "SELECT COUNT(*) FROM $tableName");
    $existingRows = (int)pg_fetch_result($result, 0, 0);
    pg_free_result($result);
    if ($existingRows >= $targetRows) {
        return;
    }

    pg_query($connection, "TRUNCATE TABLE $tableName");

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

        pg_query(
            $connection,
            "INSERT INTO $tableName (id, name, amount, created_at, payload) VALUES " . implode(',', $values)
        );
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
        $result = pg_query($connection, $query);
        while (($row = pg_fetch_row($result)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2])
                + strlen((string)$row[3])
                + strlen((string)$row[4]);
        }
        pg_free_result($result);
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $result = pg_query($connection, $query);
        while (($row = pg_fetch_row($result)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2])
                + strlen((string)$row[3])
                + strlen((string)$row[4]);
            $rowCount++;
        }
        pg_free_result($result);
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
        $result = pg_query($connection, $query);
        while (pg_fetch_row($result) !== false) {
            $checksum++;
        }
        pg_free_result($result);
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $result = pg_query($connection, $query);
        while (pg_fetch_row($result) !== false) {
            $checksum++;
            $rowCount++;
        }
        pg_free_result($result);
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
        $result = pg_query($connection, $query);
        while (($row = pg_fetch_row($result)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2]);
        }
        pg_free_result($result);
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $result = pg_query($connection, $query);
        while (($row = pg_fetch_row($result)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2]);
            $rowCount++;
        }
        pg_free_result($result);
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

if (!extension_loaded('pgsql')) {
    throw new RuntimeException('PHP extension pgsql is not loaded.');
}

$host = env_or_default('PGHOST', env_or_default('POSTGRES_HOST', '127.0.0.1'));
$port = env_int('PGPORT', env_int('POSTGRES_PORT', 5432));
$user = env_or_default('PGUSER', env_or_default('POSTGRES_USER', 'dart'));
$password = env_or_default('PGPASSWORD', env_or_default('POSTGRES_PASSWORD', 'dart'));
$database = env_or_default('PGDATABASE', env_or_default('POSTGRES_DATABASE', 'dart_test'));
$benchTable = env_or_default('BENCH_TABLE', 'bench_rows_php_pgsql');
$secure = env_bool('POSTGRES_SECURE', false);
$iterations = env_int('BENCH_ITERATIONS', 2000);
$connectIterations = env_int('BENCH_CONNECT_ITERATIONS', 25);
$warmupIterations = env_int('BENCH_WARMUP_ITERATIONS', 200);
$resultSetIterations = env_int('BENCH_RESULTSET_ITERATIONS', 20);
$resultSetWarmupIterations = env_int('BENCH_RESULTSET_WARMUP_ITERATIONS', 5);
$resultSetSizes = array_values(array_filter(array_map(
    fn($value) => (int)trim($value),
    explode(',', env_or_default('BENCH_RESULTSET_SIZES', '10,1000,10000'))
), fn($value) => $value > 0));

$connection = pgsql_connect_bench($host, $port, $user, $password, $database, $secure);
$versionResult = pg_query($connection, "SELECT version(), current_setting('server_version_num')");
$server = [
    'version' => pg_fetch_result($versionResult, 0, 0),
    'server_version_num' => pg_fetch_result($versionResult, 0, 1),
];
pg_free_result($versionResult);
pg_close($connection);

$connectStart = hrtime(true);
for ($i = 0; $i < $connectIterations; $i++) {
    $connection = pgsql_connect_bench($host, $port, $user, $password, $database, $secure);
    pg_close($connection);
}
$connectElapsedNs = hrtime(true) - $connectStart;

$connection = pgsql_connect_bench($host, $port, $user, $password, $database, $secure);
ensure_benchmark_rows($connection, max($resultSetSizes), $benchTable);

$textChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $result = pg_query($connection, 'SELECT 1');
    $textChecksum += (int)pg_fetch_result($result, 0, 0);
    pg_free_result($result);
}

$textStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $result = pg_query($connection, 'SELECT 1');
    $textChecksum += (int)pg_fetch_result($result, 0, 0);
    pg_free_result($result);
}
$textElapsedNs = hrtime(true) - $textStart;

$parameterChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $result = pg_query_params($connection, 'SELECT $1::int + $2::int', [40, 2]);
    $parameterChecksum += (int)pg_fetch_result($result, 0, 0);
    pg_free_result($result);
}

$parameterStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $result = pg_query_params($connection, 'SELECT $1::int + $2::int', [40, 2]);
    $parameterChecksum += (int)pg_fetch_result($result, 0, 0);
    pg_free_result($result);
}
$parameterElapsedNs = hrtime(true) - $parameterStart;

pg_prepare($connection, 'bench_select_add', 'SELECT $1::int + $2::int');
$preparedChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $result = pg_execute($connection, 'bench_select_add', [40, 2]);
    $preparedChecksum += (int)pg_fetch_result($result, 0, 0);
    pg_free_result($result);
}

$preparedStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $result = pg_execute($connection, 'bench_select_add', [40, 2]);
    $preparedChecksum += (int)pg_fetch_result($result, 0, 0);
    pg_free_result($result);
}
$preparedElapsedNs = hrtime(true) - $preparedStart;

$resultSets = [];
$resultSetsDrain = [];
$resultSetsSimple = [];
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
    $resultSets["rows_$size"] = benchmark_result_set(
        $connection,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
}

pg_close($connection);

$connectTotalMs = $connectElapsedNs / 1000000;
$textTotalMs = $textElapsedNs / 1000000;
$parameterTotalMs = $parameterElapsedNs / 1000000;
$preparedTotalMs = $preparedElapsedNs / 1000000;

echo json_encode([
    'driver' => 'php_pgsql',
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
    'result_sets' => $resultSets,
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), PHP_EOL;
