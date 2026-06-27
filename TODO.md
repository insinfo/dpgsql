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
- Corrigida compatibilidade ORM/PDO para strings ISO em colunas tipadas: parametros `String` sem `DpgsqlDbType` explicito agora usam inferencia PostgreSQL (`Infer String Parameters As Unknown=true`) e sao enviados em texto, permitindo `INSERT`/`WHERE` em `timestamp`, `timestamptz`, `inet`, etc.; quem quiser o comportamento antigo usa `Infer String Parameters As Unknown=false` ou tipo explicito `DpgsqlDbType.text`.
- Adicionados pontos de entrada sem string para configuracao: `DpgsqlConnection.fromConnectionStringBuilder()` e `DpgsqlDataSource.fromConnectionStringBuilder()`. O adaptador `DpgsqlPDO` do `eloquent` passou a montar `DpgsqlConnectionStringBuilder` diretamente a partir do `PDOConfig`, evitando converter toda configuracao para connection string antes de abrir conexao/pool.
- `Search Path`, `Application Name`, `Statement Timeout`, `Lock Timeout` e `Idle In Transaction Session Timeout` agora sao aplicados pelo proprio `dpgsql` a partir do `DpgsqlConnectionStringBuilder` em conexoes diretas e pooled. O `DpgsqlPDO` deixou de executar esses `SET` manualmente e usa apenas configuracao do driver; `onOpen` fica reservado para hooks customizados.
- Executado localmente com `DPGSQL_RESTART_COMMAND='gsudo Restart-Service postgresql-x64-16 -Force'`: a query em voo falhou com EOF, a conexao foi marcada como nao reutilizavel, o pool descartou o conector quebrado e a proxima operacao conseguiu executar `SELECT 42` em nova conexao.
- Confirmado que `SocketBinaryInput` notifica fechamento/erro do socket, `DpgsqlConnector.isConnected` passa para `false`, `DpgsqlDataSource` faz health check antes/depois do reset, e o adaptador `DpgsqlPDO` chama `markUnusable()` em falhas de conexao.
- Lido `C:\MyDartProjects\new_sali\backend\scripts\ci\schema_sali.sql`; tipos relevantes encontrados: inteiros, `numeric`, `real`, `boolean`, `text`/`varchar`/`char`, `date`, `timestamp`, `time`, arrays `integer[]`/`text[]`, `uuid`, `jsonb` e `inet`.
- Para o schema atual do Sali, a lacuna de tipo mais concreta era `inet`.
- Implementados tipos e handlers para `DpgsqlInet`, `DpgsqlCidr` e `DpgsqlMacAddress`, cobrindo leitura texto/binaria, escrita binaria, `DpgsqlDbType.inet/cidr/macaddr/macaddr8`, resolucao por valor/tipo e `toJson()` textual para uso em mapas/JSON.
- Decidido que `inet`, `cidr`, `macaddr` e `macaddr8` decodificam como `String` por padrao (`Decode Network Types As String=true`) para compatibilidade com `postgres_fork`/`postgres` e ORMs; quem quiser estilo Npgsql-like usa `Decode Network Types As String=false`.
- Corrigida compatibilidade Sali/Eloquent para colunas `uuid`: `uuid` agora decodifica como `String` por padrao (`Decode Uuid As String=true`), evitando quebrar modelos que tipam IDs como `String?`; quem quiser o objeto forte `DpgsqlUuid` usa `Decode Uuid As String=false`.
- Corrigida compatibilidade Sali/Eloquent para `json_agg`/`json_build_object` e colunas `json/jsonb`: JSON agora decodifica como valores Dart (`Map`/`List`/escalares) por padrao, evitando entregar strings JSON para models que esperam mapas; quem quiser texto cru usa `Decode Json As String=true` ou `PgResultMode.rawText`.
- `DpgsqlUuid` e `DpgsqlBitString` tambem ganharam `toJson()` textual, reduzindo risco ao serializar `executeMaps()` em APIs.
- Testes adicionados/ajustados em `types_test.dart` e `real_type_decode_test.dart` cobrindo `inet`, `cidr`, `macaddr` e parametros explicitos.
- Validacao local: `dart analyze`, `timeout-cli.exe 30 dart test test\types_test.dart`, `timeout-cli.exe 30 dart test test\real_type_decode_test.dart -j 1 --chain-stack-traces` e `timeout-cli.exe 60 dart test test\real_restart_recovery_test.dart -j 1 --chain-stack-traces` passando.
- Para uso no Sali/Eloquent, o conjunto atual cobre os tipos do schema inspecionado; ainda falta teste de carga real do `new_sali` com pool, `executeMaps()`, timezone `America/Sao_Paulo`, serializacao JSON e consultas grandes do `processo_repository.dart`.
- Adicionada API `DpgsqlDataSource.onOpen`/`DpgsqlDataSourceBuilder.configureOnOpen`, no estilo `settings.onOpen`, e teste real `real_data_source_on_open_test.dart` cobrindo troca de `client_encoding` para `LATIN1` e `TimeZone=America/Sao_Paulo` em conexao fisica pooled.

## Progresso 2026-06-27 (benchmark Sali vs postgresql-fork)

- Investigado benchmark real do `new_sali/backend` (`benchmark/db_driver_benchmark.dart`) comparando `driver_implementation=dpgsql` contra `postgres`/`postgresql-fork` com pool, queries reais `processos_page` e `andamentos_page`.
- Diagnostico principal: as queries do benchmark nao possuem parametros; o `dpgsql` usava Simple Query Protocol nesse caso, entao o PostgreSQL retornava colunas em formato texto e o driver fazia parse de `int`/`timestamp` por linha. O `postgresql-fork`, no caminho `query()`, usa Extended Query Protocol e pede resultados binarios mesmo sem parametros.
- Adicionada opcao `Use Extended Query For Unparameterized Commands`/`useExtendedQueryForUnparameterizedCommands`, desligada por padrao para preservar semantica de Simple Query e multiplos statements, mas disponivel para workloads ORM/query builder de SELECT unico repetido.
- `DpgsqlConnector.executeReader()` agora usa Parse/Bind/Describe/Execute/Sync sem parametros quando essa opcao esta ligada, permitindo resultado binario em consultas sem parametros.
- O adaptador `DpgsqlPDO` do `eloquent` liga essa opcao por padrao, aproximando o hot path do `postgresql-fork` no SALI.
- Validacao local: `dart analyze`, `timeout-cli.exe 30 dart test test\datasource_builder_test.dart test\real_type_decode_test.dart -j 1 --chain-stack-traces` e `timeout-cli.exe 30 dart test test\dpgsql_querybuilder_test.dart -j 1 --chain-stack-traces` passando.
- Resultado local curto antes/depois no `new_sali/backend` (`pool=true`, `poolSize=16`, `concurrency=1`):
  - antes: `processos_page` `dpgsql` ~2.60 ms vs `postgres` ~0.68 ms; `andamentos_page` `dpgsql` ~4.31 ms vs `postgres` ~0.56 ms;
  - depois: `processos_page` `dpgsql` ~0.85 ms vs `postgres` ~0.49 ms; `andamentos_page` `dpgsql` ~1.26 ms vs `postgres` ~0.62 ms.
- Resultado local curto concorrente (`iterations=500`, `warmup=50`, `concurrency=8`): throughput ficou muito mais proximo (`processos_page` ~1173 qps `dpgsql` vs ~1186 qps `postgres`; `andamentos_page` ~1269 qps `dpgsql` vs ~1187 qps `postgres`), embora as latencias por operacao ainda mostrem variancia no benchmark.
- Proxima otimizacao clara: auto-prepare/cache de `RowDescription` para comandos sem parametros, para evitar reenviar `Parse`/`Describe` em SELECTs repetidos e permitir usar o fast path preparado de `executeMaps()`.
- Implementado auto-prepare para `executeMaps()` sem parametros quando `Use Extended Query For Unparameterized Commands=true`, reutilizando `RowDescription` cacheado e usando o fast path preparado de mapas.
- `PostgresMessageReader` ganhou `tryReadMessage()` e `DpgsqlConnector` passou a drenar mensagens ja disponiveis para uma fila interna, aproximando o comportamento do `MessageFramer` do `postgresql-fork` e reduzindo `await` por mensagem quando o socket ja entregou um bloco maior.
- `executeMaps()` preparado ganhou cache de metadados de mapa por statement (`columnNames`, OIDs e handlers) e leitor bruto especializado para o caminho preparado, evitando parte do processamento generico por mensagem no hot path.
- `MemoryBinaryInput` e `BinaryOutput` deixaram de criar `ByteData.sublistView` para inteiros primitivos, usando shifts diretos em leituras/escritas big-endian.
- `DpgsqlDataSource` recebeu fast path para pool com `No Reset On Close=true`, evitando health check/reset/pruning por query quando ha conector idle valido; `DpgsqlConnection.close()` tambem evita `async` real no retorno seguro ao pool.
- `DpgsqlCommand` passou a executar comandos sem parametros e nao preparados diretamente pela conexao, sem criar `DpgsqlCommandExecutionPlan` por execucao.
- O adaptador `DpgsqlPDO` do `eloquent` passou a chamar `DpgsqlConnection.executeMaps()` diretamente para queries com retorno, evitando criar `DpgsqlCommand` no caminho de SELECT/RETURNING.
- Resultado AOT local no `new_sali/backend` apos as otimizacoes (`iterations=4000`, `warmup=500`, `pool=true`, `poolSize=16`):
  - `concurrency=1`: `select_1` `dpgsql` 0.23 ms vs `postgres` 0.18 ms; `processos_page` 0.30 ms vs 0.28 ms; `andamentos_page` 0.40 ms vs 0.43 ms (`dpgsql` mais rapido nesse cenario).
  - `concurrency=8`: `select_1` `dpgsql` 1.28 ms vs `postgres` 0.84 ms; `processos_page` 1.61 ms vs 1.54 ms; `andamentos_page` 2.03 ms vs 2.17 ms (`dpgsql` mais rapido nesse cenario).
- Executado `benchmarks/run_driver_comparison.ps1` em rodada curta AOT (`BENCH_ITERATIONS=200`, `BENCH_RESULTSET_ITERATIONS=5`, rows `10,1000`) sem regressao consideravel: `dpgsql_aot` ficou a frente de `postgres_fork` em `SELECT 1` (0.143 ms vs 0.163 ms), prepared (0.163 ms vs 0.182 ms), `maps_1000` (2.518 ms vs 4.087 ms) e `full_1000` (2.044 ms vs 3.782 ms). A unica perda Dart relevante na amostra foi parametro pequeno sem prepare (`dpgsql_aot` 0.192 ms vs `postgres_fork` 0.176 ms).
- Diagnostico atual: no benchmark interno puro de driver, `dpgsql_aot` ja vence `postgres_fork` na maioria dos cenarios medidos; no SALI/Eloquent, a diferenca restante aparece principalmente em `select_1` e vem de custo fixo de adapter/pool/execucao por query, nao de decode de linhas.
- Repetido benchmark AOT do SALI com amostra maior (`iterations=10000`, `warmup=1000`, `pool=true`, `poolSize=16`):
  - `concurrency=1`: `select_1` `dpgsql` 0.23 ms vs `postgres` 0.17 ms; `processos_page` 0.30 ms vs 0.27 ms; `andamentos_page` 0.40 ms vs 0.42 ms (`dpgsql` mais rapido nessa query real).
  - `concurrency=8`: `select_1` `dpgsql` 1.22 ms vs `postgres` 0.73 ms; `processos_page` 1.41 ms vs 1.56 ms; `andamentos_page` 1.81 ms vs 1.91 ms. Com concorrencia, `dpgsql` venceu as duas queries reais do SALI medidas e perdeu apenas no microcaso `select_1`.
- Repetido `benchmarks/run_driver_comparison.ps1` com amostra maior (`BENCH_ITERATIONS=1000`, `BENCH_RESULTSET_ITERATIONS=10`, rows `1000,3000,10000`):
  - Contra Dart: `dpgsql_aot` venceu `postgres_fork` e `postgres_3` em `SELECT 1`, drain/simple/maps/full result sets e aplicacao typed JSON; ainda ficou levemente atras do `postgres_fork` em parametro/prepared pequeno nessa amostra (`param` 0.184 ms vs 0.178 ms; `prepared` 0.189 ms vs 0.173 ms).
  - Contra PHP: `php_pgsql`/`PDO_PGSQL` ainda vencem em escalares pequenos e mapas tipados puros (`maps_10000`: `dpgsql_aot` 19.896 ms, `php_pgsql` 13.181 ms, `php_pdo_pgsql` 17.475 ms), mas `dpgsql_aot` vence em result sets `simple` grandes (`simple_10000`: 5.749 ms vs 8.191/9.665 ms), em `drain_3000/10000`, em `rawText maps_10000` comparavel ao estilo PHP (12.306 ms vs `php_pgsql` maps 13.181 ms e `PDO` 17.475 ms), e no benchmark de aplicacao com classe tipada + JSON (`typed_json_10000`: 32.293 ms vs `php_pgsql` 43.471 ms e `PDO` 44.891 ms).
  - Conclusao: `dpgsql` ja e competitivo/superior em cenarios Dart e em workloads de aplicacao tipada; para vencer PHP nativo em mapas tipados puros ainda falta reduzir custo de materializacao `Map<String, dynamic>` e decode de `numeric/timestamp` ou usar `PgResultMode.rawText` quando a semantica desejada for PHP-like.

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
- Tipos basicos, arrays, JSON/JSONB (`Map`/`List` por padrao, texto cru via opt-in), geometricos, ranges, full-text search, large objects, UUID (`String` por padrao, `DpgsqlUuid` via opt-in), bit/varbit e network types (`inet`, `cidr`, `macaddr`, `macaddr8`; `String` por padrao, objetos `Dpgsql*` via opt-in).
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
