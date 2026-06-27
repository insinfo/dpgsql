# TODO dpgsql

## Objetivo

Criar um driver PostgreSQL de alto desempenho em Dart, inspirado no Npgsql, mantendo a API publica com prefixo `Dpgsql*`.

Referencias principais:

- `C:\MyDartProjects\npgsql\referencias\npgsql-main`
- `C:\MyDartProjects\dpgsql\referencias\npgsql`
- `C:\MyDartProjects\dpgsql\referencias`

Diretrizes do port:

- Manter nomes de classes, arquivos e metodos proximos ao Npgsql quando isso facilitar diff e manutencao, mas sem trocar a API publica para `Npgsql*`.
- Preservar o objetivo de driver Dart puro, sem dependencias runtime externas.
- Priorizar protocolo estendido, pooling, prepared statements, COPY, leitura eficiente de linhas e benchmarks reais.
- Usar `rg` para busca no codigo fonte.
- Usar `timeout-cli` para validacoes locais com limite.

## Progresso 2026-06-26 (pool recovery + schema Sali)

- Adicionado teste real opt-in `real_restart_recovery_test.dart`, ativado por `DPGSQL_RESTART_COMMAND`, para reiniciar/matar o PostgreSQL durante uma query em andamento e validar recuperacao do pool.
- Executado localmente com `DPGSQL_RESTART_COMMAND='gsudo Restart-Service postgresql-x64-16 -Force'`: a query em voo falhou com EOF, a conexao foi marcada como nao reutilizavel, o pool descartou o conector quebrado e a proxima operacao conseguiu executar `SELECT 42` em nova conexao.
- Confirmado que `SocketBinaryInput` notifica fechamento/erro do socket, `DpgsqlConnector.isConnected` passa para `false`, `DpgsqlDataSource` faz health check antes/depois do reset, e o adaptador `DpgsqlPDO` chama `markUnusable()` em falhas de conexao.
- Lido `C:\MyDartProjects\new_sali\backend\scripts\ci\schema_sali.sql`; tipos relevantes encontrados: inteiros, `numeric`, `real`, `boolean`, `text`/`varchar`/`char`, `date`, `timestamp`, `time`, arrays `integer[]`/`text[]`, `uuid`, `jsonb` e `inet`.
- Para o schema atual do Sali, a lacuna de tipo mais concreta era `inet`.
- Implementados tipos e handlers para `DpgsqlInet`, `DpgsqlCidr` e `DpgsqlMacAddress`, cobrindo leitura texto/binaria, escrita binaria, `DpgsqlDbType.inet/cidr/macaddr/macaddr8`, resolucao por valor/tipo e `toJson()` textual para uso em mapas/JSON.
- Decidido que `inet`, `cidr`, `macaddr` e `macaddr8` decodificam como `String` por padrao (`Decode Network Types As String=true`) para compatibilidade com `postgres_fork`/`postgres` e ORMs; quem quiser estilo Npgsql-like usa `Decode Network Types As String=false`.
- `DpgsqlUuid` e `DpgsqlBitString` tambem ganharam `toJson()` textual, reduzindo risco ao serializar `executeMaps()` em APIs.
- Testes adicionados/ajustados em `types_test.dart` e `real_type_decode_test.dart` cobrindo `inet`, `cidr`, `macaddr` e parametros explicitos.
- Validacao local: `dart analyze`, `timeout-cli.exe 30 dart test test\types_test.dart`, `timeout-cli.exe 30 dart test test\real_type_decode_test.dart -j 1 --chain-stack-traces` e `timeout-cli.exe 60 dart test test\real_restart_recovery_test.dart -j 1 --chain-stack-traces` passando.
- Para uso no Sali/Eloquent, o conjunto atual cobre os tipos do schema inspecionado; ainda falta teste de carga real do `new_sali` com pool, `executeMaps()`, timezone `America/Sao_Paulo`, serializacao JSON e consultas grandes do `processo_repository.dart`.
- Adicionada API `DpgsqlDataSource.onOpen`/`DpgsqlDataSourceBuilder.configureOnOpen`, no estilo `settings.onOpen`, e teste real `real_data_source_on_open_test.dart` cobrindo troca de `client_encoding` para `LATIN1` e `TimeZone=America/Sao_Paulo` em conexao fisica pooled.

## Estado Atual

Core implementado:

- Conexao, handshake, SSL/TLS, cleartext, MD5 e SCRAM-SHA-256.
- Simple Query e Extended Query Protocol.
- `DpgsqlConnection`, `DpgsqlCommand`, `DpgsqlDataReader`, `DpgsqlTransaction`, `DpgsqlBatch`.
- Pool robusto em `DpgsqlDataSource`, com fila FIFO, timeout, warmup, pruning, metricas basicas e descarte seguro de conectores ocupados.
- Prepared statements explicitos e auto-prepare por conexao fisica com LRU.
- Pipeline mode e batch pipelined com tratamento de erro e streaming de resultados.
- COPY binario IN/OUT e COPY raw stream basico.
- `PgRow`, `forEachPgRow`, `executeRows`, `executePgRows`, `executeMaps`, `executeScalar`.
- Timezone configuravel com `latest_all` e `latest_10y`, default robusto em `latest_all` quando IANA esta ligado.
- Encoding PostgreSQL com aliases comuns e codecs internos.
- Tipos basicos, arrays, JSON/JSONB, geometricos, ranges, full-text search, large objects, UUID, bit/varbit e network types (`inet`, `cidr`, `macaddr`, `macaddr8`; `String` por padrao, objetos `Dpgsql*` via opt-in).
- Scaffold de replicacao logica com mensagens principais e keepalive.
- CI com PostgreSQL real 14/15/16/17 e Dart 3.6.2.

Decisoes consolidadas:

- A API publica deve continuar `Dpgsql*`.
- `latest_all` e o default para robustez historica; `latest_10y` e opt-in para binario/runtime mais enxuto.
- Benchmarks comparativos com `postgres`/`postgres_fork` ficam no pacote isolado `benchmarks`, fora do analyzer principal do pacote.
- `TimeZone` sem `Use IANA Time Zone Database=true` continua sendo apenas configuracao de sessao PostgreSQL.

## Proximo Marco

Fechar uma camada mais completa estilo Npgsql para uso real de aplicacao:

- COPY avancado com wrappers text/csv ergonomicos, testes grandes e benchmarks.
- Tipos PostgreSQL avancados mais usados em sistemas reais.
- Observabilidade minima de producao.
- Alta disponibilidade basica com multi-host e failover.
- Benchmarks com percentis, concorrencia, pool, bytes alocados/op e GC.

## Criterio de Lancamento

Status honesto em 2026-06-26:

- Pode ser lancado como `0.x`/beta tecnico para integracao controlada e benchmark real.
- Pode ser usado em piloto no `eloquent`/`new_sali` atras de `driver_implementation: 'dpgsql'`, mantendo fallback para `postgres`.
- Ainda nao deve ser tratado como `1.0` estavel de producao geral, porque faltam observabilidade, alta disponibilidade, cobertura de carga real e alguns contratos avancados do Npgsql.

Minimo para piloto no Sali:

- [x] Criar `DpgsqlPDO` em `C:\MyDartProjects\eloquent\lib\src\pdo\dpgsql`.
- [x] Criar `DpgsqlPDOTransaction`.
- [x] Registrar `case 'dpgsql'` em `PostgresConnector.createConnection`.
- [x] Garantir que `Connection.getDriverName()` retorne `pgsql` quando `driver_implementation == 'dpgsql'`.
- [x] Adicionar dependencia local/git de `dpgsql` no `eloquent`.
- [x] Traduzir `PDOConfig` para connection string Dpgsql: host, port, database, username, password, sslmode, charset, timezone, poolsize, application_name e timeouts.
- [x] Aplicar no open/reset: `search_path`, `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` e `application_name`.
- [x] Usar `executeMaps()` para `PDOResults`, evitando `row.toColumnMap()`.
- [x] Testar transacao via `runInTransaction` em teste real de query builder.
- [x] Inspecionar `schema_sali.sql` e cobrir tipos usados no schema atual, incluindo `inet`.
- [x] Testar recuperacao do pool apos restart real do PostgreSQL via `DPGSQL_RESTART_COMMAND`.
- [ ] Testar rollback e excecao dentro da transacao.
- [ ] Rodar suite ampla do `eloquent` com `driver_implementation: 'dpgsql'`.
- [ ] Rodar testes/integracao do `new_sali\backend`, principalmente `processo_repository` e fluxos stateful.
- [ ] Rodar carga concorrente com pool igual ao ambiente real (`poolsize` do Sali).
- [x] Tratar explicitamente bindings `DateTime` do `eloquent` para `dpgsql`, preservando o objeto Dart tipado em vez de formatar como `text`.

Minimo para considerar producao no Sali:

- [ ] CI verde no `dpgsql`, `eloquent` e `new_sali`.
- [ ] Benchmark real com consultas do Sali e pool concorrente.
- [ ] Comparacao contra `postgres_fork` atual em latencia p50/p95/p99.
- [x] Teste de reconexao/falha de backend PostgreSQL com restart real opt-in.
- [ ] Metricas basicas de pool e comandos expostas para diagnostico.
- [ ] Plano de rollback simples para voltar `driver_implementation` para `postgres`.

## Prioridade P0

- [ ] Confirmar CI verde apos a exclusao de `benchmarks/**` do analyzer principal.
- [ ] Finalizar e revisar `DpgsqlRawCopyStream` antes de commit futuro.
- [ ] Cobrir descarte de conexao pooled quando COPY import/export fica aberto.
- [ ] Adicionar benchmark grande de COPY IN/OUT com CSV, TEXT e BINARY.
- [ ] Implementar `foldPgRows` para agregacoes de altissima vazao sem callback por linha.
- [ ] Adicionar fast path de `executeScalar` para caminho nao preparado quando possivel.
- [ ] Reorganizar benchmarks para p50/p95/p99, ops/s, bytes alocados/op e GC.

## Roadmap por Area

### Builders, Factory e ADO-like

Feito:

- [x] `DpgsqlDataSourceBuilder` basico.
- [x] `DpgsqlSlimDataSourceBuilder` basico.
- [x] `DpgsqlFactory.instance`.
- [x] Helpers `DpgsqlDataSource.create`, `createFromBuilder`, `createConnection`, `createCommand`.
- [x] `DpgsqlCommandBuilder` basico com quote/unquote e geracao explicita de INSERT/UPDATE/DELETE.
- [x] `DpgsqlDataAdapter` basico para preencher `List<Map<String, dynamic>>` e preservar eventos row updating/updated.
- [x] `DpgsqlMetricsOptions` como extension point publico compativel com o formato Npgsql.

Pendente:

- [ ] Hooks avancados no builder para logging, tracing, password providers e type mapper.
- [ ] Compatibilidade ADO-like adicional onde fizer sentido em Dart.

### COPY Avancado

Feito:

- [x] COPY binary import/export.
- [x] `DpgsqlRawCopyStream` para `COPY FROM STDIN` e `COPY TO STDOUT`.
- [x] `beginRawBinaryCopy`, `beginTextImport`, `beginTextExport`.
- [x] `writeStream`, `read`, `readAllBytes`, `readAsString`.
- [x] Callback `onProgress` por bytes transferidos.
- [x] Suporte raw a CSV/TEXT/BINARY controlado pelo SQL do usuario.

Pendente:

- [ ] Wrappers dedicados para text reader/writer.
- [ ] Wrappers dedicados para CSV reader/writer.
- [ ] Progress callbacks por linha quando o formato permitir.
- [ ] Testes de COPY grande e cancelamento sob carga.
- [ ] Benchmark COPY IN/OUT 100k/1M rows.
- [ ] Integrar estado de COPY aberto ao retorno seguro de conexao ao pool.

### Tipos Avancados

Feito:

- [x] Tipos basicos, arrays, JSON/JSONB, geometricos e ranges.
- [x] `DpgsqlDecimal` e parsing de `numeric` texto.
- [x] Full-text search: `DpgsqlTsVector`, `DpgsqlTsQuery`.
- [x] Large objects.
- [x] `DpgsqlUuid`.
- [x] `DpgsqlBitString` para `bit`/`varbit`.

Pendente:

- [ ] Refinar `numeric`/`decimal` dedicado e `money`.
- [x] `inet`, `cidr`, `macaddr`, `macaddr8` com modo compatibilidade `String` por padrao e modo tipado por opt-in.
- [ ] `hstore`.
- [ ] `ltree`.
- [ ] `pg_lsn`.
- [ ] `record`/composite.
- [ ] enum, domain e user-defined types.
- [ ] multirange.
- [ ] cube.
- [ ] Testes reais de roundtrip para cada familia de tipo.

### Replicacao

Feito:

- [x] `DpgsqlReplicationConnection`.
- [x] Parser de mensagens logicas principais: Begin, Commit, Relation, Insert, Update, Delete.
- [x] KeepAlive/status update basico.

Pendente:

- [ ] Validacao real contra servidor PostgreSQL configurado com logical replication.
- [ ] Completar `pgoutput`: Truncate, Type, Origin e Message.
- [ ] Streaming transactions.
- [ ] Prepared transactions.
- [ ] Replicacao fisica.
- [ ] Testes de slots/publications com cleanup seguro.

### Observabilidade

Feito:

- [x] `DpgsqlMetricsOptions` publico como extension point inicial.

Pendente:

- [ ] Metricas de pool: checkout latency, busy/idle/total/waiting, timeouts, prunes.
- [ ] Metricas de comando: latencia, bytes enviados/recebidos, rows, failures.
- [ ] Logging estruturado.
- [ ] Tracing/OpenTelemetry.
- [ ] Eventos diagnosticos para conexao, pool, command, COPY, batch e pipeline.

### Alta Disponibilidade

Pendente:

- [ ] Multi-host connection string.
- [ ] `TargetSessionAttributes`.
- [ ] Load balancing entre hosts elegiveis.
- [ ] Retry de hosts em abertura de conexao.
- [ ] Host recheck/blacklist temporaria apos falha.
- [ ] Testes com hosts indisponiveis e failover.

### Protocolo, Batch e Cursor

Feito:

- [x] Extended Query Protocol basico.
- [x] Close Statement e Close Portal.
- [x] Pipeline mode.
- [x] Batch pipelined.
- [x] Erros parciais em batch via `PostgresBatchException`.

Pendente:

- [ ] Multiplos result sets por batch.
- [ ] Portal reuse para multiplos `Execute`.
- [ ] Describe Portal completo.
- [ ] Cancel/timeout granular por operacao.
- [ ] DECLARE CURSOR.
- [ ] FETCH FORWARD/BACKWARD.
- [ ] API `Stream<PgRow>` com backpressure.
- [ ] CLOSE CURSOR automatico.

### Performance

Feito:

- [x] `PgRow` lazy com view sobre payload/offsets.
- [x] Fast paths para inteiros, bool, texto, float/double, timestamp e numeric.
- [x] `executeMaps` com fast path preparado e `PgResultMode.rawText`.
- [x] Reuso de plano em `DpgsqlCommand` quando estrutura de parametros nao muda.
- [x] Auto-prepare por conexao fisica.
- [x] Benchmarks Dart/PHP com result sets tipados, maps e aplicacao JSON.

Pendente:

- [ ] Percentis p50/p95/p99 nos benchmarks.
- [ ] Bytes alocados/op e GC.
- [ ] Concorrencia com pool (`poolsize=20` e maiores).
- [ ] Benchmark com queries reais do `new_sali`/`eloquent`.
- [ ] Benchmark de single-row map/first.
- [ ] `foldPgRows`/agregadores especializados.
- [ ] Reduzir copias no parser e no writer.
- [ ] Writer contiguo com patch de length estilo Npgsql.
- [ ] Backpressure configuravel no pipeline: max commands, max bytes, max in-flight.
- [ ] Caches adicionais para handlers/OIDs no extended protocol sem prepare.

## Validacao Local

Comandos rapidos:

```powershell
dart analyze
timeout-cli.exe 30 dart test test\types_test.dart
timeout-cli.exe 30 dart test test\timezone_encoding_test.dart
timeout-cli.exe 30 dart test test\real_type_decode_test.dart
timeout-cli.exe 30 dart test test\real_raw_copy_stream_test.dart
```

Suite completa:

```powershell
timeout-cli.exe 120 dart test --concurrency 1
```

Benchmark rapido:

```powershell
$env:BENCH_ITERATIONS='5'
$env:BENCH_CONNECT_ITERATIONS='1'
$env:BENCH_RESULTSET_ITERATIONS='1'
$env:BENCH_WARMUP_ITERATIONS='1'
$env:BENCH_RESULTSET_WARMUP_ITERATIONS='1'
$env:BENCH_RESULTSET_SIZES='10'
timeout-cli.exe 30 powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks\run_driver_comparison.ps1 -TimeoutSeconds 30
```

Benchmark mais util:

```powershell
$env:BENCH_ITERATIONS='2000'
$env:BENCH_CONNECT_ITERATIONS='25'
$env:BENCH_RESULTSET_ITERATIONS='20'
$env:BENCH_WARMUP_ITERATIONS='200'
$env:BENCH_RESULTSET_WARMUP_ITERATIONS='5'
$env:BENCH_RESULTSET_SIZES='10,1000,10000'
timeout-cli.exe 120 powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks\run_driver_comparison.ps1 -TimeoutSeconds 120
```

Relatorio:

- `benchmarks/reports/driver-comparison/summary.md`

## Historico Recente

### 2026-06-26 - Integracao Eloquent/Sali com DpgsqlPDO

- `C:\MyDartProjects\eloquent` recebeu dependencia local `dpgsql` via `path: ../dpgsql` e `publish_to: none` para desenvolvimento local.
- Criado `pdo/dpgsql` com `DpgsqlPDO` e `DpgsqlPDOTransaction`.
- `PostgresConnector` registra `driver_implementation: 'dpgsql'`.
- `Connection.getDriverName()` trata `dpgsql` como `pgsql`, preservando grammar/schema manager PostgreSQL.
- `DpgsqlPDO` converte `PDOConfig` para connection string Dpgsql, aplica sessao (`search_path`, `timezone`, `application_name`, statement/lock/idle timeouts) e usa `executeMaps()` para resultados com rows.
- Ajustado `prepareBindings()` do `eloquent` para preservar `bool` em PostgreSQL, evitando envio de `false` como `0` em parametros binarios tipados.
- Adicionado teste real `test/dpgsql_querybuilder_test.dart` cobrindo query builder, bindings, mapas e transacao com `dpgsql`.
- Validacao local no `eloquent`: `dart analyze` e `timeout-cli.exe 30 dart test test\dpgsql_querybuilder_test.dart -j 1 --chain-stack-traces` passando.
- Robustez apos restart/falha do PostgreSQL: `SocketBinaryInput` notifica fechamento/erro do socket para o conector, `DpgsqlConnection.markUnusable()` permite impedir retorno ao pool, `DpgsqlDataSource` revalida a conexao depois do reset e `DpgsqlPDO` marca conexoes pooled como inutilizaveis em falhas de rede/protocolo antes de devolver ao pool.

### 2026-06-26 - ADO-like inicial e metrics extension point

- Adicionado `DpgsqlCommandBuilder` com quote/unquote de identificadores e geracao explicita de comandos INSERT/UPDATE/DELETE.
- Adicionado `DpgsqlDataAdapter` com comandos tipados, `fill()` para `List<Map<String, dynamic>>` e callbacks row updating/updated.
- Adicionado `DpgsqlMetricsOptions` como extension point publico para futura observabilidade estilo Npgsql.
- Novos exports publicos em `lib/dpgsql.dart`.
- Validacao local: `dart analyze` e `timeout-cli.exe 30 dart test test\dpgsql_ado_like_test.dart` passando.

### 2026-06-26 - Timezone `latest_all` configuravel

- Decidido que `latest_all` e o padrao quando `Use IANA Time Zone Database=true`, evitando erros historicos em datas antigas como ano 2000.
- Gerados `pg_timezone_data_all.dart` e `pg_timezone_data_10y.dart`.
- Adicionado `PgTimeZoneDatabaseScope`.
- `TimeZoneSettings` ganhou `ianaTimeZoneDatabaseScope`.
- `DpgsqlConnectionStringBuilder` parseia `IANA Time Zone Database Scope=latest_all|latest_10y`.
- Cache de locations considera o escopo para nao misturar bancos.
- Testes cobrem parsing do escopo e offset historico de `America/Sao_Paulo`.

### 2026-06-26 - Builders e Factory Dpgsql

- Adicionado `DpgsqlDataSourceBuilder`.
- Adicionado `DpgsqlSlimDataSourceBuilder`.
- Adicionado `DpgsqlFactory.instance`.
- `DpgsqlDataSource` ganhou helpers de criacao.
- Novos exports publicos e testes de builder/factory.

### 2026-06-26 - `DpgsqlRawCopyStream`

- Iniciado port de `NpgsqlRawCopyStream` com API `Dpgsql*`.
- Adicionados raw stream import/export para COPY TEXT/CSV/BINARY.
- API cobre leitura, escrita, stream, cancelamento, dispose e progresso por bytes.
- Cancelamento de COPY FROM marca conexao como nao reutilizavel no pool.
- Teste real cobre import/export CSV, progresso e cancelamento.

### 2026-06-26 - UUID, bit/varbit e `executeScalar`

- Adicionado `DpgsqlUuid`.
- Adicionado `DpgsqlBitString`.
- Implementados `UuidHandler` e `BitStringHandler`.
- `DpgsqlDbType` ganhou `bit`.
- Adicionados `DpgsqlCommand.executeScalar()` e `DpgsqlConnection.executeScalar()`.
- Conector ganhou fast path preparado para scalar.

### 2026-06-26 - Maps para Eloquent/Sali

- Adicionados `toMap`, `readAllMaps`, `executeMaps`.
- Implementado fast path preparado para mapas tipados e `PgResultMode.rawText`.
- Benchmarks passaram a medir `result_sets_maps`.
- `application_typed_json` mostrou `dpgsql_aot` competitivo contra PHP quando a aplicacao tambem hidrata tipos e serializa JSON.

### 2026-06-26 - TimeZoneSettings e encodings

- `TimeZoneSettings` tornou configuravel o decode de `timestamp`, `timestamptz` e `date`.
- `Throw On DateTime Infinity` permite escolher entre `null` e excecao para infinity.
- `TimeZone` e `client_encoding` sao enviados no startup e restaurados pelo pool.
- Encodings PostgreSQL comuns foram mapeados para codecs internos.
- Testes reais cobrem `LATIN1` e roundtrip de texto nao ASCII.

### 2026-06-26 - Hot path de leitura

- `DpgsqlDataReader` ganhou getters tipados e `isDBNull`.
- `DataRowMessage` passou a guardar payload/offsets/lengths.
- `PgRow` ganhou fast paths e decode lazy.
- `executeRows`, `executePgRows` e `forEachPgRow` reduzem materializacao desnecessaria.
- `prepare()` cacheia `RowDescription`.

### 2026-06-26 - Pool, pipeline e auto-prepare

- Pool ganhou max size real, fila FIFO, timeout, warmup, pruning e metricas.
- Conectores com reader/transacao/pipeline aberto sao descartados ao retornar ao pool.
- Auto-prepare por conexao fisica com LRU e fechamento de statements expulsos.
- Pool preserva prepared statements ativos e evita `DISCARD ALL` quando necessario.

### 2026-06-26 - CI, docs e publicacao

- API publica renomeada para `Dpgsql*`.
- Criados `README.md`, `CHANGELOG.md` e `LICENSE`.
- Workflow GitHub Actions usa Dart 3.6.2 e PostgreSQL 14/15/16/17.
- Testes reais usam `DPGSQL_TEST_DB`.
- `benchmarks/**` foi isolado do analyzer principal porque possui `pubspec.yaml` proprio.

## Historico Legado Condensado

### 2025-04-12

- Criado esqueleto de I/O binario: `BinaryInput`, `SocketBinaryInput`, `MemoryBinaryInput`, `BinaryOutput`, `SocketBinaryOutput`, `MemoryBinaryOutput`.
- Criadas mensagens basicas de frontend/backend e testes de protocolo.

### 2025-12-05

- Implementado conector inicial, handshake, autenticacao cleartext/MD5, exceptions e API publica inicial.
- Adicionado Extended Query Protocol, parametros, pooling basico, type handlers basicos e SCRAM-SHA-256.
- Implementados arrays, transacoes, COPY proto, COPY binary import/export, prepare e SQL rewrite.
- Adicionados SSL/TLS, text parsing, JSON/JSONB, geometricos e ranges.

### 2025-12-07

- Implementados Large Object Manager e streams.
- Implementados Full-Text Search Types.
- Implementado `PreparedStatementManager`.
- Adicionado metadata de schema (`DpgsqlDbColumn` apos renomeacao).

### 2025-12-08

- Melhorado writer/buffering, pipeline buffering e flush condicional.
- Adicionados metodos unsigned em I/O binario.
- Corrigidos fluxos de pipeline, batch e pooling para evitar hangs em mocks.
- Melhorado tratamento de erro em pipeline.

### 2025-12-09

- Pipeline passou a suportar streaming incremental de comandos pendentes.
- Reader tornou-se pipeline-aware.
- Batch pipelined passou a mapear comandos e resultados.
- Adicionados testes reais de pipeline.
- `SocketBinaryInput` reduziu copias e passou a usar pool de `Uint8List`.
- `PostgresBatchException` passou a preservar falhas parciais.

## Notas de Timezone e Encoding

- `timestamp without time zone` deve preservar o valor local sem converter para UTC.
- `timestamptz` e armazenado em UTC pelo PostgreSQL e deve respeitar a configuracao de decode do driver.
- `date`, `timestamp` e `timestamptz` tem cuidado especial com offsets historicos e `infinity`.
- No Dart/Linux, offsets historicos de `DateTime` podem divergir do offset atual; por isso o driver usa configuracao explicita e banco IANA vendorizado quando necessario.
- Para sistemas que precisam ler datas historicas, usar `latest_all`.
- Para sistemas que so lidam com anos recentes e querem menor inicializacao de dados, usar `IANA Time Zone Database Scope=latest_10y`.
- `Encoding` controla codec local do driver; `Client Encoding`/`PGCLIENTENCODING` controla o valor enviado ao PostgreSQL.
