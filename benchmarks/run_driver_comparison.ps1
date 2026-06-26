param(
  [string]$PhpPath = "C:\php\php-8.3.11-nts\php.exe",
  [string]$ComposerPhar = "C:\ProgramData\ComposerSetup\bin\composer.phar",
  [string]$HostName = $(if ($env:PGHOST) { $env:PGHOST } elseif ($env:POSTGRES_HOST) { $env:POSTGRES_HOST } else { "127.0.0.1" }),
  [int]$Port = $(if ($env:PGPORT) { [int]$env:PGPORT } elseif ($env:POSTGRES_PORT) { [int]$env:POSTGRES_PORT } else { 5432 }),
  [string]$User = $(if ($env:PGUSER) { $env:PGUSER } elseif ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { "dart" }),
  [string]$Password = $(if ($env:PGPASSWORD) { $env:PGPASSWORD } elseif ($env:POSTGRES_PASSWORD) { $env:POSTGRES_PASSWORD } else { "dart" }),
  [string]$Database = $(if ($env:PGDATABASE) { $env:PGDATABASE } elseif ($env:POSTGRES_DATABASE) { $env:POSTGRES_DATABASE } else { "dart_test" }),
  [string]$Secure = $(if ($env:POSTGRES_SECURE) { $env:POSTGRES_SECURE } else { "false" }),
  [int]$Iterations = $(if ($env:BENCH_ITERATIONS) { [int]$env:BENCH_ITERATIONS } else { 2000 }),
  [int]$ConnectIterations = $(if ($env:BENCH_CONNECT_ITERATIONS) { [int]$env:BENCH_CONNECT_ITERATIONS } else { 25 }),
  [int]$ResultSetIterations = $(if ($env:BENCH_RESULTSET_ITERATIONS) { [int]$env:BENCH_RESULTSET_ITERATIONS } else { 20 }),
  [int]$WarmupIterations = $(if ($env:BENCH_WARMUP_ITERATIONS) { [int]$env:BENCH_WARMUP_ITERATIONS } else { 200 }),
  [int]$ResultSetWarmupIterations = $(if ($env:BENCH_RESULTSET_WARMUP_ITERATIONS) { [int]$env:BENCH_RESULTSET_WARMUP_ITERATIONS } else { 5 }),
  [int]$TimeoutSeconds = $(if ($env:BENCH_TIMEOUT_SECONDS) { [int]$env:BENCH_TIMEOUT_SECONDS } else { 120 }),
  [switch]$SkipComposerInstall,
  [switch]$SkipDartCompile
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$resultsDir = Join-Path $root "benchmarks\reports\driver-comparison"
$binDir = Join-Path $root "benchmarks\bin"
$phpBenchmarkDir = Join-Path $root "benchmarks\php_benchmark"
$dartAotExe = Join-Path $binDir "benchmark_dpgsql.exe"

function Convert-BenchBool([string]$value) {
  switch ($value.Trim().ToLowerInvariant()) {
    "1" { return $true }
    "true" { return $true }
    "yes" { return $true }
    "on" { return $true }
    "0" { return $false }
    "false" { return $false }
    "no" { return $false }
    "off" { return $false }
    default { throw "Invalid boolean value: $value" }
  }
}

$secureBool = Convert-BenchBool $Secure

New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

if (-not (Test-Path $PhpPath)) {
  throw "PHP executable not found: $PhpPath"
}

if (-not $SkipComposerInstall) {
  if (-not (Test-Path $ComposerPhar)) {
    throw "Composer phar not found: $ComposerPhar"
  }

  Write-Host "Installing PHP benchmark dependencies..."
  Push-Location $phpBenchmarkDir
  try {
    & $PhpPath $ComposerPhar install --no-interaction --prefer-dist
    if ($LASTEXITCODE -ne 0) {
      throw "Composer install exited with code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

if (-not $SkipDartCompile) {
  Write-Host "Compiling dpgsql benchmark to AOT..."
  timeout-cli.exe $TimeoutSeconds dart compile exe (Join-Path $root "benchmarks\benchmark_dpgsql.dart") -o $dartAotExe
  if ($LASTEXITCODE -ne 0) {
    throw "dart compile exe exited with code $LASTEXITCODE"
  }
} elseif (-not (Test-Path $dartAotExe)) {
  throw "Dart AOT executable not found: $dartAotExe"
}

function Set-BenchEnv([string]$driverName, [string]$benchTable) {
  $env:PGHOST = $HostName
  $env:PGPORT = "$Port"
  $env:PGUSER = $User
  $env:PGPASSWORD = $Password
  $env:PGDATABASE = $Database
  $env:POSTGRES_HOST = $HostName
  $env:POSTGRES_PORT = "$Port"
  $env:POSTGRES_USER = $User
  $env:POSTGRES_PASSWORD = $Password
  $env:POSTGRES_DATABASE = $Database
  $env:POSTGRES_SECURE = if ($secureBool) { "true" } else { "false" }
  $env:BENCH_DRIVER_NAME = $driverName
  $env:BENCH_TABLE = $benchTable
  $env:BENCH_ITERATIONS = "$Iterations"
  $env:BENCH_CONNECT_ITERATIONS = "$ConnectIterations"
  $env:BENCH_RESULTSET_ITERATIONS = "$ResultSetIterations"
  $env:BENCH_WARMUP_ITERATIONS = "$WarmupIterations"
  $env:BENCH_RESULTSET_WARMUP_ITERATIONS = "$ResultSetWarmupIterations"
}

function Run-And-Capture([string]$name, [scriptblock]$command) {
  $outPath = Join-Path $resultsDir "$name.json"
  $errPath = Join-Path $resultsDir "$name.err.txt"
  Write-Host "Running $name..."
  try {
    $output = & $command 2> $errPath
    if ($LASTEXITCODE -ne 0) {
      throw "Command exited with code $LASTEXITCODE"
    }
    $lastLine = ($output | Where-Object { $_ -and $_.Trim() -ne "" } | Select-Object -Last 1)
    if (-not $lastLine) {
      throw "Command produced no JSON output"
    }
    $lastLine | Set-Content -Path $outPath -Encoding UTF8
  } catch {
    $message = $_.Exception.Message
    $payload = [ordered]@{
      driver = $name
      error = $message
      stderr = if (Test-Path $errPath) { (Get-Content $errPath -Raw) } else { "" }
    }
    ($payload | ConvertTo-Json -Depth 4 -Compress) | Set-Content -Path $outPath -Encoding UTF8
    Write-Warning "$name failed: $message"
  }
}

Set-BenchEnv "dpgsql_aot" "bench_rows_dpgsql_aot"
Run-And-Capture "dpgsql_aot" {
  timeout-cli.exe $TimeoutSeconds $dartAotExe
}

Set-BenchEnv "php_pgsql" "bench_rows_php_pgsql"
Run-And-Capture "php_pgsql" {
  timeout-cli.exe $TimeoutSeconds $PhpPath (Join-Path $root "benchmarks\benchmark_php_pgsql.php")
}

Set-BenchEnv "php_pdo_pgsql" "bench_rows_php_pdo_pgsql"
Run-And-Capture "php_pdo_pgsql" {
  timeout-cli.exe $TimeoutSeconds $PhpPath (Join-Path $root "benchmarks\benchmark_php_pdo_pgsql.php")
}

Set-BenchEnv "php_pgasync" "bench_rows_php_pgasync"
Run-And-Capture "php_pgasync" {
  timeout-cli.exe $TimeoutSeconds $PhpPath (Join-Path $root "benchmarks\benchmark_php_pgasync.php")
}

Set-BenchEnv "php_amphp_postgres" "bench_rows_php_amphp_postgres"
Run-And-Capture "php_amphp_postgres" {
  timeout-cli.exe $TimeoutSeconds $PhpPath (Join-Path $root "benchmarks\benchmark_php_amphp_postgres.php")
}

$jsonFiles = @(
  (Join-Path $resultsDir "dpgsql_aot.json"),
  (Join-Path $resultsDir "php_pgsql.json"),
  (Join-Path $resultsDir "php_pdo_pgsql.json"),
  (Join-Path $resultsDir "php_pgasync.json"),
  (Join-Path $resultsDir "php_amphp_postgres.json")
)

dart run (Join-Path $root "benchmarks\compare_benchmarks.dart") @jsonFiles |
  Set-Content -Path (Join-Path $resultsDir "summary.md") -Encoding UTF8

Write-Host "Results written to $resultsDir"
Write-Host "Summary: $(Join-Path $resultsDir "summary.md")"
