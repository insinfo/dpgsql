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

function pdo_connect_bench(
    string $host,
    int $port,
    string $user,
    string $password,
    string $database,
    bool $secure
): PDO {
    $sslMode = $secure ? 'require' : 'disable';
    $dsn = sprintf(
        'pgsql:host=%s;port=%d;dbname=%s;sslmode=%s',
        $host,
        $port,
        $database,
        $sslMode
    );
    return new PDO($dsn, $user, $password, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_NUM,
    ]);
}

function ensure_benchmark_rows(PDO $pdo, int $targetRows, string $tableName): void
{
    $pdo->exec("
        CREATE TABLE IF NOT EXISTS $tableName (
            id INTEGER PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            amount NUMERIC(10, 2) NOT NULL,
            created_at TIMESTAMP NOT NULL,
            payload TEXT NOT NULL
        )
    ");

    $existingRows = (int)$pdo->query("SELECT COUNT(*) FROM $tableName")->fetchColumn();
    if ($existingRows >= $targetRows) {
        return;
    }

    $pdo->exec("TRUNCATE TABLE $tableName");

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

        $pdo->exec(
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
    PDO $pdo,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_NUM)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2])
                + strlen((string)$row[3])
                + strlen((string)$row[4]);
        }
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_NUM)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2])
                + strlen((string)$row[3])
                + strlen((string)$row[4]);
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
    PDO $pdo,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        $stmt = $pdo->query($query);
        while ($stmt->fetch(PDO::FETCH_NUM) !== false) {
            $checksum++;
        }
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $stmt = $pdo->query($query);
        while ($stmt->fetch(PDO::FETCH_NUM) !== false) {
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
    PDO $pdo,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_NUM)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2]);
        }
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_NUM)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2]);
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
    PDO $pdo,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_ASSOC)) !== false) {
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
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_ASSOC)) !== false) {
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

function benchmark_application_typed_json(
    PDO $pdo,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_ASSOC)) !== false) {
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
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_ASSOC)) !== false) {
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

if (!extension_loaded('pdo_pgsql')) {
    throw new RuntimeException('PHP extension pdo_pgsql is not loaded.');
}

$host = env_or_default('PGHOST', env_or_default('POSTGRES_HOST', '127.0.0.1'));
$port = env_int('PGPORT', env_int('POSTGRES_PORT', 5432));
$user = env_or_default('PGUSER', env_or_default('POSTGRES_USER', 'dart'));
$password = env_or_default('PGPASSWORD', env_or_default('POSTGRES_PASSWORD', 'dart'));
$database = env_or_default('PGDATABASE', env_or_default('POSTGRES_DATABASE', 'dart_test'));
$benchTable = env_or_default('BENCH_TABLE', 'bench_rows_php_pdo_pgsql');
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

$pdo = pdo_connect_bench($host, $port, $user, $password, $database, $secure);
$serverRow = $pdo->query("SELECT version(), current_setting('server_version_num')")->fetch(PDO::FETCH_NUM);
$server = [
    'version' => $serverRow[0],
    'server_version_num' => $serverRow[1],
];
$pdo = null;

$connectStart = hrtime(true);
for ($i = 0; $i < $connectIterations; $i++) {
    $pdo = pdo_connect_bench($host, $port, $user, $password, $database, $secure);
    $pdo = null;
}
$connectElapsedNs = hrtime(true) - $connectStart;

$pdo = pdo_connect_bench($host, $port, $user, $password, $database, $secure);
ensure_benchmark_rows($pdo, max($resultSetSizes), $benchTable);

$textChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $textChecksum += (int)$pdo->query('SELECT 1')->fetchColumn();
}

$textStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $textChecksum += (int)$pdo->query('SELECT 1')->fetchColumn();
}
$textElapsedNs = hrtime(true) - $textStart;

$parameterStmt = $pdo->prepare('SELECT ?::int + ?::int');
$parameterChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $parameterStmt->execute([40, 2]);
    $parameterChecksum += (int)$parameterStmt->fetchColumn();
}

$parameterStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $parameterStmt->execute([40, 2]);
    $parameterChecksum += (int)$parameterStmt->fetchColumn();
}
$parameterElapsedNs = hrtime(true) - $parameterStart;

$preparedStmt = $pdo->prepare('SELECT ?::int + ?::int');
$a = 40;
$b = 2;
$preparedStmt->bindParam(1, $a, PDO::PARAM_INT);
$preparedStmt->bindParam(2, $b, PDO::PARAM_INT);

$preparedChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $preparedStmt->execute();
    $preparedChecksum += (int)$preparedStmt->fetchColumn();
}

$preparedStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $preparedStmt->execute();
    $preparedChecksum += (int)$preparedStmt->fetchColumn();
}
$preparedElapsedNs = hrtime(true) - $preparedStart;

$resultSets = [];
$resultSetsDrain = [];
$resultSetsSimple = [];
$resultSetsMaps = [];
$applicationTypedJson = [];
foreach ($resultSetSizes as $size) {
    $resultSetsDrain["rows_$size"] = benchmark_result_set_drain(
        $pdo,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $resultSetsSimple["rows_$size"] = benchmark_result_set_simple(
        $pdo,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $resultSetsMaps["rows_$size"] = benchmark_result_set_maps(
        $pdo,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $applicationTypedJson["rows_$size"] = benchmark_application_typed_json(
        $pdo,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
    $resultSets["rows_$size"] = benchmark_result_set(
        $pdo,
        $benchTable,
        $size,
        $resultSetWarmupIterations,
        $resultSetIterations
    );
}

$pdo = null;

$connectTotalMs = $connectElapsedNs / 1000000;
$textTotalMs = $textElapsedNs / 1000000;
$parameterTotalMs = $parameterElapsedNs / 1000000;
$preparedTotalMs = $preparedElapsedNs / 1000000;

echo json_encode([
    'driver' => 'php_pdo_pgsql',
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
