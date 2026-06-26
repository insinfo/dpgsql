<?php

require __DIR__ . '/php_benchmark/vendor/autoload.php';

use EventLoop\EventLoop;
use PgAsync\Client;
use Rx\Observer\CallbackObserver;

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

function pgasync_client(
    string $host,
    int $port,
    string $user,
    string $password,
    string $database,
    bool $secure,
    bool $autoDisconnect = false
): Client {
    return new Client([
        'host' => $host,
        'port' => (string)$port,
        'user' => $user,
        'password' => $password,
        'database' => $database,
        'tls' => $secure ? 'require' : 'disable',
        'max_connections' => 1,
        'auto_disconnect' => $autoDisconnect,
    ], EventLoop::getLoop());
}

function pgasync_pump(float $seconds = 0.001): void
{
    $loop = EventLoop::getLoop();
    $timer = $loop->addTimer($seconds, function () use ($loop): void {
        $loop->stop();
    });
    $loop->run();
    $loop->cancelTimer($timer);
}

function pgasync_collect($observable, callable $onRow, float $timeoutSeconds = 30.0): array
{
    $loop = EventLoop::getLoop();
    $checksum = 0;
    $rowCount = 0;
    $error = null;

    $timeout = $loop->addTimer($timeoutSeconds, function () use (&$error, $loop): void {
        $error = new RuntimeException('PgAsync benchmark query timed out.');
        $loop->stop();
    });

    $observable->subscribe(new CallbackObserver(
        function ($row) use (&$checksum, &$rowCount, $onRow): void {
            $checksum += $onRow($row);
            $rowCount++;
        },
        function ($e) use (&$error, $loop): void {
            $error = $e instanceof Throwable ? $e : new RuntimeException((string)$e);
            $loop->stop();
        },
        function () use ($loop): void {
            $loop->futureTick(function () use ($loop): void {
                $loop->stop();
            });
        }
    ));

    $loop->run();
    $loop->cancelTimer($timeout);

    if ($error !== null) {
        throw $error;
    }

    return [$checksum, $rowCount];
}

function first_value(array $row)
{
    $values = array_values($row);
    return $values[0] ?? null;
}

function ensure_benchmark_rows(Client $client, int $targetRows, string $tableName): void
{
    pgasync_collect($client->query("
        CREATE TABLE IF NOT EXISTS $tableName (
            id INTEGER PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            amount NUMERIC(10, 2) NOT NULL,
            created_at TIMESTAMP NOT NULL,
            payload TEXT NOT NULL
        )
    "), fn() => 0);

    [$existingRows] = pgasync_collect(
        $client->query("SELECT COUNT(*) AS count FROM $tableName"),
        fn(array $row) => (int)first_value($row)
    );
    if ($existingRows >= $targetRows) {
        return;
    }

    pgasync_collect($client->query("TRUNCATE TABLE $tableName"), fn() => 0);

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

        pgasync_collect(
            $client->query(
                "INSERT INTO $tableName (id, name, amount, created_at, payload) VALUES " . implode(',', $values)
            ),
            fn() => 0
        );
    }
}

function benchmark_result_set(
    Client $client,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        [$partial] = pgasync_collect($client->query($query), function (array $row): int {
            return (int)$row['id']
                + strlen((string)$row['name'])
                + strlen((string)$row['amount'])
                + strlen((string)$row['created_at'])
                + strlen((string)$row['payload']);
        });
        $checksum += $partial;
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        [$partial, $rows] = pgasync_collect($client->query($query), function (array $row): int {
            return (int)$row['id']
                + strlen((string)$row['name'])
                + strlen((string)$row['amount'])
                + strlen((string)$row['created_at'])
                + strlen((string)$row['payload']);
        });
        $checksum += $partial;
        $rowCount += $rows;
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
    Client $client,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        [$partial] = pgasync_collect($client->query($query), fn() => 1);
        $checksum += $partial;
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        [$partial, $rows] = pgasync_collect($client->query($query), fn() => 1);
        $checksum += $partial;
        $rowCount += $rows;
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
    Client $client,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        [$partial] = pgasync_collect($client->query($query), function (array $row): int {
            return (int)$row['id'] + strlen((string)$row['name']) + strlen((string)$row['payload']);
        });
        $checksum += $partial;
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        [$partial, $rows] = pgasync_collect($client->query($query), function (array $row): int {
            return (int)$row['id'] + strlen((string)$row['name']) + strlen((string)$row['payload']);
        });
        $checksum += $partial;
        $rowCount += $rows;
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
$benchTable = checked_table_name(env_or_default('BENCH_TABLE', 'bench_rows_php_pgasync'));
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

$client = pgasync_client($host, $port, $user, $password, $database, $secure);
[$versionChecksum] = pgasync_collect(
    $client->query("SELECT version() AS version, current_setting('server_version_num') AS server_version_num"),
    function (array $row) use (&$server): int {
        $server = [
            'version' => $row['version'],
            'server_version_num' => $row['server_version_num'],
        ];
        return 0;
    }
);

$connectStart = hrtime(true);
for ($i = 0; $i < $connectIterations; $i++) {
    $connectClient = pgasync_client($host, $port, $user, $password, $database, $secure, true);
    pgasync_collect($connectClient->query('SELECT 1'), fn(array $row) => (int)first_value($row));
    $connectClient->closeNow();
    pgasync_pump();
}
$connectElapsedNs = hrtime(true) - $connectStart;

ensure_benchmark_rows($client, max($resultSetSizes), $benchTable);

$textChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    [$partial] = pgasync_collect($client->query('SELECT 1'), fn(array $row) => (int)first_value($row));
    $textChecksum += $partial;
}

$textStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    [$partial] = pgasync_collect($client->query('SELECT 1'), fn(array $row) => (int)first_value($row));
    $textChecksum += $partial;
}
$textElapsedNs = hrtime(true) - $textStart;

$parameterChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    [$partial] = pgasync_collect(
        $client->executeStatement('SELECT $1::int + $2::int', [40, 2]),
        fn(array $row) => (int)first_value($row)
    );
    $parameterChecksum += $partial;
}

$parameterStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    [$partial] = pgasync_collect(
        $client->executeStatement('SELECT $1::int + $2::int', [40, 2]),
        fn(array $row) => (int)first_value($row)
    );
    $parameterChecksum += $partial;
}
$parameterElapsedNs = hrtime(true) - $parameterStart;

$preparedChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    [$partial] = pgasync_collect(
        $client->executeStatement('SELECT $1::int + $2::int', [40, 2]),
        fn(array $row) => (int)first_value($row)
    );
    $preparedChecksum += $partial;
}

$preparedStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    [$partial] = pgasync_collect(
        $client->executeStatement('SELECT $1::int + $2::int', [40, 2]),
        fn(array $row) => (int)first_value($row)
    );
    $preparedChecksum += $partial;
}
$preparedElapsedNs = hrtime(true) - $preparedStart;

$resultSets = [];
$resultSetsDrain = [];
$resultSetsSimple = [];
foreach ($resultSetSizes as $size) {
    $resultSetsDrain["rows_$size"] = benchmark_result_set_drain(
        $client,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $resultSetsSimple["rows_$size"] = benchmark_result_set_simple(
        $client,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $resultSets["rows_$size"] = benchmark_result_set(
        $client,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
}

$client->closeNow();
pgasync_pump();

$connectTotalMs = $connectElapsedNs / 1000000;
$textTotalMs = $textElapsedNs / 1000000;
$parameterTotalMs = $parameterElapsedNs / 1000000;
$preparedTotalMs = $preparedElapsedNs / 1000000;

echo json_encode([
    'driver' => env_or_default('BENCH_DRIVER_NAME', 'php_pgasync'),
    'host' => $host,
    'port' => $port,
    'database' => $database,
    'secure' => $secure,
    'connect_mode' => 'warm_auth_cache',
    'server' => $server ?? [],
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
