# TODO dpgsql

## Progresso 2026-06-26 (maps para Eloquent/Sali)

- Lido o fluxo atual do `new_sali`/`eloquent`: `DatabaseService` passa `timezone=America/Sao_Paulo` como configuracao de sessao e os repositorios consomem massivamente `List<Map<String, dynamic>>`/`PDOResults`.
- Confirmado que `eloquent` com `postgres_fork` materializa `PDOResults` via `row.toColumnMap()`, entao o caminho critico para substituir o driver no Sali precisa gerar mapas tipados com baixo overhead.
- Adicionado `DpgsqlDataReader.toMap()` e `DpgsqlDataReader.readAllMaps()` para materializar rows nomeadas direto do reader.
- Adicionado `DpgsqlCommand.executeMaps()` e `DpgsqlConnection.executeMaps()`.
- Implementado fast path preparado em `DpgsqlConnector.executeMaps()`, reutilizando `RowDescription` cacheado e pulando `Describe Portal`, com decode direto para `Map<String, dynamic>` sem criar `List<Object?>` intermediaria.
- `benchmarks/benchmark_dpgsql.dart`, `benchmark_dart_packages.dart` e `compare_benchmarks.dart` agora medem `result_sets_maps`, aproximando o benchmark do padrao usado pelo Eloquent/Sali.
- Scripts PHP (`ext-pgsql`, `PDO_PGSQL`, `voryx/PgAsync` e `amphp/postgres`) agora tambem emitem `result_sets_maps`, usando array associativo/fetch associativo quando aplicavel.
- Benchmarks passaram a incluir `3000` linhas por padrao (`10,1000,3000,10000`) e o runner recebeu parametro `ResultSetSizes`.
- Resultado local com `BENCH_ITERATIONS=200`, `BENCH_RESULTSET_ITERATIONS=10`, rows `1000,3000`: `dpgsql_aot` segue liderando os drivers Dart em `maps_3000` (8.850 ms vs 11.396 ms `postgres_fork` e 22.165 ms `postgres_3`), mas ainda perde para PHP nativo (`php_pgsql` 4.215 ms e `php_pdo_pgsql` 5.141 ms). Diferenca importante: PHP entrega strings em arrays associativos, enquanto `dpgsql` decodifica valores tipados (`double`/`DateTime`) no `executeMaps()`.
- Resultado local com rows `10000` (`BENCH_RESULTSET_ITERATIONS=5`): `dpgsql_aot` continua liderando Dart em `maps_10000` (29.945 ms vs 36.305 ms `postgres_fork` e 67.953 ms `postgres_3`), mas PHP nativo ainda vence (`php_pgsql` 13.292 ms, `php_pdo_pgsql` 17.717 ms). `php_pgasync` e `amphp/postgres` ficam atras de `dpgsql` nesse volume.
- Adicionado `PgResultMode.rawText`, modo opt-in estilo PHP/ext-pgsql que pede formato texto no `Bind` e expoe valores como `String/null` em `getValue`, `toMap`, `readAllMaps` e `executeMaps`, mantendo `PgResultMode.typed` como padrao.
- Implementado fast path preparado para `executeMaps(resultMode: PgResultMode.rawText)`, reutilizando `RowDescription` cacheado e evitando `Describe Portal` por execucao.
- Resultado local apos `rawText` com rows `10000` (`BENCH_RESULTSET_ITERATIONS=5`): mapas tipados `dpgsql_aot` 32.114 ms, mapas `rawText` 18.754 ms, `php_pgsql` 14.334 ms e `php_pdo_pgsql` 16.944 ms. O modo PHP-like reduziu bastante a diferenca e ficou mais rapido que `PDO_PGSQL` em uma rodada anterior/variante, mas nesta amostra ainda nao superou `ext-pgsql`.
- Adicionado benchmark `application_typed_json`, que força PHP e Dart a converter valores, hidratar classe tipada e serializar JSON por row. Resultado local final com rows `10000` (`BENCH_RESULTSET_ITERATIONS=5`): `dpgsql_aot` 44.139 ms, `php_pgsql` 48.168 ms, `php_pdo_pgsql` 47.225 ms, `php_pgasync` 104.555 ms e `php_amphp_postgres` 58.729 ms. Nesse cenario mais justo de aplicacao, `dpgsql_aot` venceu as opcoes PHP medidas.
- `DpgsqlCommand` passou a reutilizar plano de comando parametrizado com checagem estrutural sem `StringBuffer` por execucao, reduzindo alocacao no hot path de comando repetido nao preparado.
- `real_type_decode_test.dart` cobre `executeMaps`, `reader.toMap()`, `reader.readAllMaps()`, `executeMaps()` preparado e `rawText` contra PostgreSQL real.
- Proximos passos:
  - criar adapter `DpgsqlPDO` no `eloquent` usando `executeMaps()` para substituir `row.toColumnMap()`;
  - medir `result_sets_maps` com `poolsize=20` e consultas reais do `processo_repository.dart`;
  - adicionar benchmark de `first`/single-row map, comum em endpoints de detalhe.
  - criar caminho `rawText` streaming sem materializar lista inteira para JSON/HTTP e medir contra `pg_fetch_assoc` em loop;
  - reduzir overhead do extended protocol parametrizado sem prepare: cache de handlers/OIDs por plano e auto-prepare mais agressivo por conexao.
  - portar o benchmark `application_typed_json` para `postgres_fork` e `postgres` para comparar hidratacao Dart completa entre drivers;
  - criar benchmark de aplicacao real (`eloquent`/`new_sali`) com hidratacao de modelos/DTOs, query builder, pool e serializacao JSON, porque o microbenchmark de driver puro favorece `ext-pgsql` escrito em C e nao mede o custo total de framework PHP.

## Progresso 2026-06-26 (TimeZoneSettings opcional)

- Lido o comportamento de timestamp/timezone em `C:\MyDartProjects\postgresql-fork`, `C:\MyDartProjects\dargres`, pacote `postgres`/isoos local e `referencias/npgsql`.
- Confirmado que `postgres`/isoos decodifica `timestamp` e `timestamptz` como UTC por padrao; `postgresql-fork` e `dargres` tambem usam flags `forceDecode*AsUTC=true` por padrao.
- Confirmado que Npgsql moderno trata `timestamp without time zone` como `DateTimeKind.Unspecified` e `timestamptz` como UTC; no Dart isso foi exposto como escolha entre `DateTime` UTC e local, ja que nao existe `DateTimeKind.Unspecified`.
- Adicionado `TimeZoneSettings` publico com flags opcionais `Force Decode Timestamp As UTC`, `Force Decode Timestamptz As UTC`, `Force Decode Date As UTC` e `Use Current Offset For Local Timestamp`.
- Adicionado `Throw On DateTime Infinity`/`ThrowOnDateTimeInfinity`: por padrao `date`, `timestamp` e `timestamptz` `infinity`/`-infinity` materializam como `null` em `executeMaps`/`getValue`, preservando compatibilidade com `postgresql-fork`/`dargres` e evitando quebra no SALI; com a flag ligada, o helper volta a lancar `ArgumentError`.
- `DpgsqlConnectionStringBuilder` agora parseia `TimeZone` e as flags de decode, propagando a configuracao para conexoes normais, pool, replicacao, type handlers, `DpgsqlDataReader` e `PgRow`.
- `DpgsqlConnector` envia `TimeZone` no startup quando configurado e o pool restaura `TimeZone`/`client_encoding` apos reset da sessao.
- Decode/encode binario de `date`, `timestamp` e `timestamptz` deixou de usar `epoch.add(Duration(...))` nos hot paths, usando calculo direto por micros desde Unix epoch para reduzir alocacoes em result sets grandes.
- Paridade configuravel com `postgresql-fork`/`dargres` para timezone nomeada: vendorizado subconjunto interno de `pg_timezone`/IANA a partir das referencias locais, sem adicionar dependencia runtime externa.
- `timestamptz` com `Force Decode Timestamptz As UTC=false` so usa nomes como `America/Sao_Paulo` e abreviacoes via banco interno quando `Use IANA Time Zone Database=true`; sem essa flag, `TimeZone` permanece apenas configuracao de sessao PostgreSQL, que e o caso atual do `new_sali`/`eloquent`.
- `lib/src/dependencies/timezone/src/env.dart` nao aponta mais para `latest.tzf`; o driver usa `pg_timezone_data.dart`, arquivo Dart gerado/versionado. `scripts/generate_pg_timezone_data.dart` agora tambem compila fontes IANA em Dart puro (`--download-iana`/`--iana`), parseando `Rule`/`Zone`/`Link` sem `zic.c` e sem `package:timezone`; o caminho `.tzf` continua disponivel apenas para comparacao/regeneracao rapida.
- Testes adicionados/ajustados em `timezone_encoding_test.dart` e `real_type_decode_test.dart` validando decode UTC default e decode local opcional em banco real.
- `real_type_decode_test.dart` cobre `timestamptz` real com `TimeZone=America/Sao_Paulo;Use IANA Time Zone Database=true`, e `timezone_encoding_test.dart` cobre que uma timezone invalida nao aciona IANA quando a flag esta desligada.

## Progresso 2026-06-26 (comparacao com postgresql-fork + hot path de leitura)

- Corrigido caminho de referencia: `C:\MyDartProjects\postgresql-fork` e o pacote `postgres_fork` local sao a versao `2.8.5`.
- Lido `postgresql-fork/lib` e `postgresql-fork/test`; a base possui fila de queries, statement reuse, transacoes, SSL, encoding, notificacoes e testes extensos de erro/concorrencia.
- `DpgsqlDataReader` ganhou getters tipados (`getInt`, `getString`, `getDouble`, `getBool`, `getDateTime`) e `isDBNull`, aproximando a API do Npgsql e reduzindo overhead em ORMs que conhecem o schema.
- `DpgsqlDataReaderImpl` passou a reaproveitar o cache lazy por result set em vez de alocar uma lista nova por linha acessada.
- Parser de `DataRow` agora le direto do `Uint8List` da mensagem, evitando `MemoryBinaryInput` e `ByteData.sublistView` no hot path.
- `BinaryInput.availableBytes` permite ao `PostgresMessageReader` evitar `await ensureBytes()` quando header/body ja estao no buffer.
- `numeric` agora decodifica para `double` por padrao, alinhado ao `DpgsqlTypesConfig.recommended()`; `DpgsqlDecimal` continua disponivel para parametros/handlers explicitos.
- `executeRows()` materializa result sets em `List<List<Object?>>` direto no conector.
- `executePgRows()` materializa `PgRow` lazy com payload/offsets, evitando decodificacao antecipada de texto em leituras grandes.
- `forEachPgRow()` processa `PgRow` transient direto do `DataRowMessage`, sem montar lista de linhas e sem copiar payload no caminho preparado.
- `PgRow` ganhou fast paths diretos para `getInt`, `getString`, `getNumericDouble` e `getDateTime`, reduzindo views temporarias em leituras sequenciais.
- `prepare()` agora cacheia `RowDescription`; execucoes preparadas materializadas pulam `Describe Portal`, seguindo mais de perto o statement reuse do `postgresql-fork`.
- Benchmark `dpgsql_aot` passou a usar getters tipados e reutilizar `DpgsqlCommand` no cenario parametrizado.
- Resultado local anterior (`PostgreSQL 16.7`, `BENCH_ITERATIONS=200`, rows 10/1000): `dpgsql_aot` liderava os drivers Dart em `SELECT 1`, prepared, drain de 1000 linhas e simple rows_1000; `postgres_fork` ainda liderava o cenario `full formatted rows_1000`.
- Resultado local apos `TimeZoneSettings` + fast path de timestamp (`PostgreSQL 16.7`, `BENCH_ITERATIONS=200`, `BENCH_RESULTSET_ITERATIONS=10`, rows_1000): `dpgsql_aot` passou a liderar tambem `full formatted rows_1000` (3.054 ms vs 4.133 ms do `postgres_fork` e 7.240 ms do `postgres_3`).
- Resultado local apos cache de plano de parametros e `forEachPgRowSync` (`PostgreSQL 16.7`, `BENCH_ITERATIONS=200`, `BENCH_RESULTSET_ITERATIONS=10`, rows_1000): `dpgsql_aot` liderou os cenarios Dart medidos (`SELECT 1`, parametrizado, prepared, drain, simple e full).
- Proximos passos para sustentar lideranca em producao:
  - repetir benchmark com amostras longas, p50/p95/p99, bytes alocados/op e GC;
  - medir com concorrencia e pool (`poolsize=20`) para aproximar o perfil do `new_sali`;
  - comparar contra PHP nativo novamente depois das mudancas;
  - implementar `foldPgRows`/agregadores especializados para reduzir overhead de callback em loops muito grandes;
  - reduzir copias no `executePgRows()` com ownership seguro do buffer de mensagem ou arena por result set;
  - revisar `numeric`/`DateTime.toString()` no benchmark full para separar custo de driver de custo de formatacao Dart;
  - comparar com o `query_queue`/`message_window` do `postgresql-fork` para portar a drenagem em lote sem perder streaming.

## Progresso 2026-06-26 (benchmarks Dart/PHP completos)

- Lido o benchmark existente `benchmarks/benchmark_dpgsql.dart`, `compare_benchmarks.dart` e `run_driver_comparison.ps1`.
- Adicionado `benchmarks/pubspec.yaml` com `postgres_fork: ^2.8.5` e `postgres: ^3.5.4`, isolando dependencias comparativas fora do pacote principal.
- Criado `benchmarks/benchmark_dart_packages.dart`, emitindo o mesmo JSON do benchmark `dpgsql_aot` para os drivers `postgres_fork` e `postgres_3`.
- `run_driver_comparison.ps1` agora compila e executa:
  - `dpgsql_aot`;
  - `postgres_fork`;
  - `postgres_3`;
  - `php_pgsql`;
  - `php_pdo_pgsql`;
  - `php_pgasync`;
  - `php_amphp_postgres`.
- `README.md` atualizado com a matriz de drivers, cenarios medidos, variaveis de ambiente e local dos relatorios.

## Progresso 2026-06-26 (publicacao + auto-prepare robusto)

- Criados `CHANGELOG.md` e `LICENSE` com MIT License (`Copyright (c) 2022-2026 Isaque Neves`).
- Lido `referencias/npgsql/src/Npgsql/PreparedStatementManager.cs` e `referencias/npgsql/test/Npgsql.Tests/AutoPrepareTests.cs` para comparar a politica de substituicao de auto-prepare.
- Lido `referencias/npgsql/test/Npgsql.Tests/Types/RangeTests.cs` e portado parsing texto de ranges para Dart.
- `PreparedStatementManager.beginAutoPrepare()` agora faz fallback para execucao sem auto-prepare quando nao existe slot seguro, em vez de lançar `Bad state: No auto-prepare slot is available`.
- `RangeHandler` agora lê ranges em formato texto (`empty`, inclusivo/exclusivo, limites infinitos e bounds entre aspas), cobrindo Simple Query e formatos emitidos pelo PostgreSQL.
- `DpgsqlRange.toString()` foi normalizado para o formato PostgreSQL/Npgsql, omitindo limites infinitos.
- `DpgsqlBinaryExporter` agora rejeita explicitamente flags de cabecalho COPY binary nao suportadas.
- Comentarios `TODO` herdados de codecs/testes foram convertidos para notas, removendo ruido de diagnostico da IDE.
- Adicionado teste unitario `prepared_statement_manager_test.dart` cobrindo cache cheio sem slot evictable.
- `auto_prepare_test.dart` reforcado com substituicoes repetidas usando `Max Auto Prepare=1`.

## Progresso 2026-06-26 (API Dpgsql + docs + testes reais)

- Renomeada a API publica de `Npgsql*` para `Dpgsql*` no codigo do pacote, testes e benchmarks, incluindo conexao, comandos, data source, parametros, transacoes, batch, tipos, schema e replicacao.
- Arquivos internos remanescentes `npgsql_*.dart` foram renomeados para `dpgsql_*.dart`, mantendo o pacote alinhado ao nome `dpgsql`.
- Criado `README.md` em ingles com badge do GitHub Actions, instalacao via Git, quick start, pooling, prepared statements, batch/pipeline, COPY, notifications, encodings, testes reais, benchmarks e notas de producao.
- Workflow `.github/workflows/dart-testing.yml` atualizado para Dart 3.6.2 e preparacao de locale `pt_BR.CP1252`, preservando matriz real PostgreSQL 14/15/16/17.
- Portados/adaptados mais testes reais inspirados em `C:\MyDartProjects\postgresql-fork\test`:
  - `real_notification_test.dart` cobre `LISTEN/NOTIFY`;
  - `real_error_recovery_test.dart` valida recuperacao apos `ErrorResponse` e rollback apos erro em transacao;
  - `real_type_decode_test.dart` cobre decodificacao real de escalares, `bytea`, array e `numeric`.
- Corrigido dreno de protocolo quando `ErrorResponse` ocorre durante `DpgsqlDataReaderImpl.init()`, garantindo que `ReadyForQuery` seja consumido antes de relancar a excecao.
- Implementado parsing texto de `bytea` nos formatos PostgreSQL hex (`\x...`) e escape legado.
- Implementado `DpgsqlDecimal.parse()` para `numeric` em texto, convertendo para a representacao base-10000 usada pelo caminho binario.

## Progresso 2026-06-26 (encodings PostgreSQL + codecs internos)

- Lido `referencias/npgsql/test/Npgsql.Tests/ConnectionTests.cs`, especialmente os cenarios `Client_encoding_*` e `Non_UTF8_Encoding`.
- `NpgsqlConnectionStringBuilder` separa agora `Encoding` (codec local do driver, estilo Npgsql) de `Client Encoding`/`PGCLIENTENCODING` (valor enviado ao PostgreSQL no startup).
- Implementado mapeamento de aliases PostgreSQL para codecs internos ja existentes:
  - `UTF8`, `SQL_ASCII`, `LATIN1-10`, `ISO_8859_5-8`;
  - `WIN1250-1254`, `WIN1256`;
  - `KOI8R`, `KOI8U`, `BIG5`, `GBK`;
  - aliases comuns como `windows-1252`, `KOI8-R`, `ISO-8859-5`.
- Encodings PostgreSQL sem codec local real no repo agora falham cedo com `UnsupportedError`, evitando fallback silencioso para UTF8.
- `NpgsqlConnector` passou a enviar `client_encoding` no `StartupMessage`; conexoes normais, pool e replicacao propagam `postgresClientEncoding`.
- Adicionado teste real `real_client_encoding_test.dart` validando `SHOW client_encoding = LATIN1` e roundtrip de texto nao-ASCII.
- Testes unitarios de encoding atualizados para verificar `WIN1252` real, aliases PostgreSQL e separacao `Encoding=windows-1252;Client Encoding=sql-ascii`.
- Validacao local: `dart analyze` sem issues e `timeout-cli.exe 30 dart test` passando (`+103 ~2`).

## Progresso 2026-06-26 (CI PostgreSQL + testes reais parametrizados)

- Lido padrao de testes do Npgsql em `referencias/npgsql/test/Npgsql.Tests/TestUtil.cs`: connection string centralizada via variavel de ambiente (`NPGSQL_TEST_DB`) com fallback local.
- Criado `test/test_config.dart` com `realConnectionString()`, `openRealConnectionOrSkip()` e `executeScalar()`, permitindo rodar testes reais tanto localmente quanto no GitHub Actions.
- Testes reais migrados para usar configuracao por ambiente: prepare, auto-prepare, COPY IN/OUT, pipeline e integracao geral.
- Adicionado teste real `real_pool_lifecycle_test.dart` validando que conexao fisica pooled preserva auto-prepared statements ao retornar para o pool.
- Adicionado workflow GitHub Actions `.github/workflows/dart-testing.yml` com nome `Dart Testing`, matriz Dart 3.6.0 x PostgreSQL 14/15/16/17, `dart analyze` e `dart run test --concurrency 1`.
- CI usa `DPGSQL_TEST_DB` apontando para um PostgreSQL real em service container (`dart_test`, usuario `dart`, senha `dart`), fazendo os testes reais falharem se o banco configurado estiver indisponivel.
- Validacao local: `dart analyze` sem issues e `timeout-cli.exe 30 dart test` passando (`+99 ~2`).

## Progresso 2026-06-26 (correcao + primeira otimizacao)

- Corrigido bug de double rewrite em SQL parametrizado: `NpgsqlCommand` agora informa ao caminho normal que o SQL ja foi reescrito, evitando perda de parametros em comandos nao preparados com `@param`.
- Adicionado teste real cobrindo `NpgsqlCommand('SELECT @a::int + @b::int')` sem `prepare()`.
- `NpgsqlDataReaderImpl` passou a reutilizar o `TypeHandlerRegistry` do `NpgsqlConnector`, evitando construir um registry completo por reader.
- `NpgsqlDataReaderImpl` agora cacheia handlers e formato texto/binario por coluna ao receber `RowDescription`, reduzindo lookup por `getValue()`.
- `prepare()` e `executeReader()` no protocolo estendido agora coalescem `Parse/Bind/Describe/Execute` e flusham no `Sync`, reduzindo flushes no socket.
- `NpgsqlConnector.executeReader()` agora resolve `TypeHandler` dos parametros uma unica vez e reaproveita para OIDs e serializacao.
- Validacao: `dart analyze` sem issues e `timeout-cli.exe 30 dart test` passando (`+86 ~2`).
- Benchmark curto local apos a rodada (`BENCH_ITERATIONS=100`, rows 10/1000): `dpgsql` melhorou em parametros/prepared, mas ainda fica atras de `php_pgsql`/`pdo_pgsql`; proxima prioridade e reduzir custo de leitura de result sets (`PgRow`/lazy decode/handlers).

## Progresso 2026-06-26 (PgRow/lazy decode)

- `DataRowMessage` deixou de materializar `List<Uint8List?>` no parse de cada linha.
- Parser de `DataRow` agora guarda `payload + columnOffsets + columnLengths`, pulando bytes por offset em `MemoryBinaryInput`.
- Getter `columns` continua existindo por compatibilidade, mas agora e lazy e so aloca quando chamado diretamente.
- `NpgsqlDataReaderImpl` passou a decodificar colunas sob demanda a partir de offset/length, com cache por linha para acessos repetidos.
- Adicionados fast paths no reader para tipos comuns (`int2/int4/int8`, `bool`, `text/varchar/bpchar/unknown`, `float4/float8`) evitando `Uint8List.sublistView` e lookup de handler nesses casos.
- Validacao: `dart analyze` limpo e `timeout-cli.exe 30 dart test` passando (`+86 ~2`).
- Benchmark curto local apos a rodada (`BENCH_ITERATIONS=100`, rows 10/1000): `rows_10` melhorou em relacao a amostras anteriores, mas `rows_1000` ainda segue muito atras do PHP; proximos gargalos provaveis sao `NUMERIC`/`TIMESTAMP`, overhead async por mensagem e comparacao de benchmark com conversoes `toString()` em tipos complexos.

## Progresso 2026-06-26 (benchmark justo + tipos complexos)

- Benchmark comparativo agora separa result sets em:
  - `drain`: apenas consumir linhas, sem acessar valores;
  - `simple`: acessar `id/name/payload`;
  - `full`: acessar `id/name/numeric/timestamp/payload`.
- Scripts PHP (`pgsql` e `pdo_pgsql`) foram atualizados para emitir as mesmas tres familias de result set.
- `compare_benchmarks.dart` agora imprime tabelas separadas para `drain`, `simple` e `full`, evitando conclusoes erradas a partir de um unico `rows_1000`.
- `NpgsqlDecimal.toString()` deixou de retornar representacao debug e passou a formatar o valor numerico base-10000.
- `NpgsqlDataReaderImpl` ganhou fast paths binarios para `timestamp/timestamptz` e `numeric`, evitando dispatch generico e `ByteData.sublistView` nesses tipos.
- Validacao: `dart analyze` limpo e `timeout-cli.exe 30 dart test` passando (`+88 ~2`).
- Benchmark curto local apos a rodada (`BENCH_ITERATIONS=100`, rows 10/1000): `full rows_1000` caiu de ~80-90 ms para ~15.7 ms/query; `simple rows_1000` ficou em ~5.8 ms/query e `drain rows_1000` em ~5.7 ms/query. O gargalo restante agora parece estar no overhead de parser/mensagens/async, nao apenas nos handlers complexos.

## Progresso 2026-06-26 (benchmarks PHP async + Dart AOT)

- `run_driver_comparison.ps1` agora compila `benchmarks/benchmark_dpgsql.dart` para AOT (`benchmarks/bin/benchmark_dpgsql.exe`) antes da medicao.
- Adicionado `benchmarks/php_benchmark/composer.json` para instalar dependencias PHP de benchmark via Composer.
- Adicionado benchmark `voryx/pgasync` (`benchmarks/benchmark_php_pgasync.php`), cobrindo caminho puro PHP/ReactPHP com protocolo PostgreSQL implementado pela biblioteca.
- Adicionado benchmark `amphp/postgres` (`benchmarks/benchmark_php_amphp_postgres.php`), cobrindo o driver async do Amp. Observacao: a versao atual `amphp/postgres` 2.2.x exige `ext-pgsql` ou `pecl-pq`, entao nao e um fallback puro PHP nesta versao.
- A comparacao agora roda cinco drivers: `dpgsql_aot`, `php_pgsql` (`ext-pgsql`), `php_pdo_pgsql`, `php_pgasync` e `php_amphp_postgres`.
- Rodada curta local (`BENCH_ITERATIONS=3`, `rows_10`) validou execucao dos cinco drivers e gerou `benchmarks/reports/driver-comparison/summary.md`.

## Progresso 2026-06-26 (pool robusto para producao)

- `NpgsqlConnectionStringBuilder` passou a reconhecer keywords de pool no estilo Npgsql: `Pooling`, `Minimum Pool Size`, `Maximum Pool Size`, `Timeout`, `Connection Idle Lifetime` e `Connection Lifetime`.
- `NpgsqlDataSource` foi refeito como pool com limite maximo real, contagem `busy/idle/total`, fila FIFO de espera e timeout de checkout.
- `NpgsqlDataSource.warmup()` pre-cria conexoes ate `Minimum Pool Size` quando chamado explicitamente.
- `dispose()` agora fecha idle, rejeita waiters pendentes e faz conexoes ocupadas serem descartadas ao retornarem.
- Pool descarta conexoes vencidas por lifetime/idle lifetime e cria substitutas para chamadas esperando quando ha capacidade.
- `poolStats` ganhou metricas de producao: `busy`, `total`, `waiting`, `max`, `min`, `waits` e `timeouts`.
- Testes adicionados para parsing das opcoes de pool, espera quando `Maximum Pool Size` e atingido, timeout de checkout e warmup.
- Validacao: `dart analyze` sem issues e `timeout-cli.exe 30 dart test` passando (`+92 ~2`).

## Progresso 2026-06-26 (pool safety e pruning)

- `NpgsqlConnection` agora rastreia readers ativos retornados pela API publica e transacao ativa.
- Fechar uma conexao pooled com reader aberto, transacao ativa ou pipeline ainda ativo agora descarta o conector fisico em vez de devolve-lo ao pool.
- `NpgsqlTransaction` passou a notificar a conexao quando `commit()`/`rollback()` completam, liberando o estado transacional para retorno seguro ao pool.
- `NpgsqlDataSource` ganhou pruning periodico configuravel via `Connection Pruning Interval`.
- Corrigida corrida de pool onde um waiter podia expirar enquanto uma nova conexao ainda estava abrindo; nesse caso o conector aberto volta para idle ou e descartado, sem vazar `busyCount`.
- Testes adicionados para descarte de conector retornado com reader ativo e transacao ativa.
- Validacao: `dart analyze` sem issues e `timeout-cli.exe 30 dart test` passando (`+94 ~2`).

## Progresso 2026-06-26 (auto-prepare por conexao fisica)

- `NpgsqlConnectionStringBuilder` passou a reconhecer `Max Auto Prepare` e `Auto Prepare Min Usages`, mantendo o default do Npgsql (`Max Auto Prepare=0`, desabilitado).
- `NpgsqlConnector` integrou `PreparedStatementManager` por conexao fisica e reutiliza statements automaticamente no caminho parametrizado do extended protocol.
- `PreparedStatementManager` agora promove candidatos por threshold, suporta `Auto Prepare Min Usages=1`, mantem slots LRU e registra statements expulsos para fechamento no backend.
- Protocolo frontend ganhou `Close Statement` e `Close Portal`; o reader ignora `CloseComplete` no fluxo extended.
- Auto-prepare agora fecha o statement preparado antigo no servidor antes de preparar um novo quando o cache LRU estoura, evitando vazamento em conexoes longas.
- Pool preserva o cache por conector fisico quando ha prepared statements ativos, evitando `DISCARD ALL` nesse caso.
- Teste real `test/auto_prepare_test.dart` valida auto-prepare na primeira execucao e LRU com `Max Auto Prepare=1`, confirmando que o servidor fica com apenas um statement preparado.
- Validacao: `dart analyze` sem issues e `timeout-cli.exe 30 dart test` passando (`+98 ~2`).

## Diagnostico de portabilidade vs Npgsql

Referencia analisada: `referencias/npgsql/src/Npgsql` e `referencias/npgsql/test/Npgsql.Benchmarks`.

Principais areas ainda faltando portar ou aprofundar:

- `NpgsqlDataSourceBuilder`, `NpgsqlSlimDataSourceBuilder` e configuracao fluente de data source.
- `NpgsqlCommandBuilder`, `NpgsqlDataAdapter`, `NpgsqlFactory` e compatibilidade ADO.NET equivalente.
- `NpgsqlRawCopyStream` e APIs COPY stream-based/CSV/TEXT.
- Tipos/conversores avancados: uuid, numeric/decimal dedicado, money, bit string, hstore, inet/cidr/macaddr, ltree, record/composite, enum, domain, multirange, cube, pg_lsn/log sequence number.
- Replicacao fisica e pgoutput completo: streaming transactions, truncate/type/origin/messages prepared transaction e extensoes equivalentes.
- Observabilidade: `NpgsqlMetricsOptions`, logging estruturado, tracing/OpenTelemetry e eventos diagnosticos.
- Multi-host/failover: `NpgsqlMultiHostDataSource`, `TargetSessionAttributes`, load balance e retry de hosts.
- Pool robusto no nivel Npgsql: ampliar validacoes de reset, warmup automatico opcional, observabilidade e comportamento sob falhas reais de rede.
- Protocolo: portal reuse, describe portal completo, cancel/timeout granular e melhor tratamento de operacao em progresso.

## Performance pendente

- Reduzir custo fixo do caminho parametrizado/preparado: benchmark curto local ainda mostra `dpgsql_aot` atras de `php_pgsql`/`pdo_pgsql` em alguns cenarios pequenos.
- Implementar fast path para `executeScalar`/`SELECT 1` sem criar reader completo quando o usuario pede um unico valor.
- Melhorar `NpgsqlDataReaderImpl`: decodificacao lazy por coluna, evitar `Map<String,int>` em hot path quando acesso e por indice, e integrar `PgRow` zero-copy.
- Revisar type handlers de `NUMERIC`, `TIMESTAMP`, `TEXT` e inteiros para reduzir alocacoes e conversoes texto/binario.
- Reusar planos de execucao/SQL reescrito em `NpgsqlCommand` nao preparado quando a estrutura de parametros nao muda.
- Aprofundar cache de prepared statements por conexao no pool: metricas publicas, cenarios de invalidez por schema change e benchmarks com auto-prepare ligado.
- Adicionar benchmarks de COPY IN/OUT, batch com multiplos result sets, read rows 1/10/100/1000 e write parameter, espelhando `test/Npgsql.Benchmarks`.

## Benchmarks criados

Arquivos:

- `benchmarks/benchmark_dpgsql.dart`
- `benchmarks/benchmark_php_pgsql.php`
- `benchmarks/benchmark_php_pdo_pgsql.php`
- `benchmarks/benchmark_php_pgasync.php`
- `benchmarks/benchmark_php_amphp_postgres.php`
- `benchmarks/php_benchmark/composer.json`
- `benchmarks/compare_benchmarks.dart`
- `benchmarks/run_driver_comparison.ps1`

Como rodar rapido:

```powershell
$env:BENCH_ITERATIONS='5'
$env:BENCH_CONNECT_ITERATIONS='1'
$env:BENCH_RESULTSET_ITERATIONS='1'
$env:BENCH_WARMUP_ITERATIONS='1'
$env:BENCH_RESULTSET_WARMUP_ITERATIONS='1'
$env:BENCH_RESULTSET_SIZES='10'
timeout-cli.exe 30 powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks\run_driver_comparison.ps1 -TimeoutSeconds 30
```

Como rodar uma medicao mais util:

```powershell
$env:BENCH_ITERATIONS='2000'
$env:BENCH_CONNECT_ITERATIONS='25'
$env:BENCH_RESULTSET_ITERATIONS='20'
$env:BENCH_WARMUP_ITERATIONS='200'
$env:BENCH_RESULTSET_WARMUP_ITERATIONS='5'
$env:BENCH_RESULTSET_SIZES='10,1000,10000'
timeout-cli.exe 120 powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks\run_driver_comparison.ps1 -TimeoutSeconds 120
```

Resultado gerado em `benchmarks/reports/driver-comparison/summary.md`.

## Validacao local curta em 2026-06-26

Ambiente: PostgreSQL 16.7 local, `127.0.0.1:5432`, database `dart_test`, usuario `dart`.

Resumo da amostra curta (`BENCH_ITERATIONS=5`, `rows_10`):

- `dpgsql`: `SELECT 1` 0.450 ms/op, parametro 1.045 ms/op, prepared 0.834 ms/op, rows_10 2.534 ms/query.
- `php_pgsql`: `SELECT 1` 0.202 ms/op, parametro 0.240 ms/op, prepared 0.227 ms/op, rows_10 0.244 ms/query.
- `php_pdo_pgsql`: `SELECT 1` 0.304 ms/op, parametro 0.130 ms/op, prepared 0.121 ms/op, rows_10 0.377 ms/query.

Esta amostra e pequena e serve apenas como validacao funcional do benchmark; ainda nao prova throughput final.


o dpgsql não parece estar no teto de performance ainda. Ele já tem uma base forte — driver Dart puro, sem dependências runtime, com protocolo estendido, pipeline, batch, COPY básico, pooling e buffers — mas o próprio código ainda mostra gargalos reais em alocação, preparação automática, decoding de linhas e benchmark/profiling. O pubspec.yaml define o projeto como “High Performance PostgreSQL Driver for Dart” e sem dependências runtime, o que é uma boa base para otimização fina.

A conclusão mais honesta é: provavelmente você já passou dos ganhos óbvios de arquitetura, mas ainda não chegou no teto. Falta transformar algumas estruturas “implementadas” em estruturas realmente usadas no hot path, medir alocação/memória, e reduzir cópias por mensagem/linha.

Onde ainda há mais ganho
1. Integrar de verdade o PreparedStatementManager

Esse é provavelmente o maior ganho funcional que ainda aparece no código. O PreparedStatementManager já existe, tem cache por SQL, contadores de hit/miss, auto-prepare candidate, threshold de uso e LRU eviction.

Mas no fluxo principal, o NpgsqlCommand.prepare() ainda gera um nome manual com prep_${hashCode} e chama connection.prepare(...); já o NpgsqlConnector.executeReader() só evita Parse quando recebe statementName, ou seja, quando alguém preparou explicitamente.

A otimização aqui seria colocar um PreparedStatementManager dentro de cada NpgsqlConnector físico. Antes de enviar Parse, o conector calcularia os OIDs dos parâmetros, consultaria o manager por (sql reescrito, parameterOids), e usaria statementName existente quando houver hit. Quando uma query passar do threshold, o conector prepara automaticamente e passa a usar Bind/Execute sem reenviar Parse.

Isso é coerente com o PostgreSQL: prepared statements nomeados vivem na sessão até serem fechados ou até o fim da sessão, enquanto o statement não nomeado é substituído pelo próximo Parse ou Query. O Npgsql também documenta prepared statements e automatic preparation como um dos caminhos mais importantes de performance, inclusive com prepared statements persistindo por conexão física dentro do pool.

Prioridade: altíssima. Isso pode reduzir bytes enviados, CPU de parse no servidor e roundtrips de preparação em workloads repetitivos.

2. Reduzir alocações no writer: hoje ainda há cópias/objetos demais

O PostgresMessageWriter já reutiliza _scratchBuffer, o que é bom. Mas em modo bufferizado ele ainda monta o payload, cria outro MemoryBinaryOutput para a mensagem completa, escreve tipo/length/payload nele e enfileira um Uint8List.

Além disso, o WriteBuffer mantém uma List<Uint8List> de mensagens pendentes e no flush() escreve uma a uma no BinaryOutput. Isso reduz flushes no socket, mas não é um buffer contíguo de protocolo; ainda há lista, objetos por mensagem e cópia para o SocketBinaryOutput.

O ideal é um WriteBuffer estilo Npgsql: um único Uint8List grande por conexão, com:

final start = buffer.position;
buffer.writeUint8(typeCode);
buffer.writeInt32(0);        // placeholder length
writeBody(buffer);
buffer.patchInt32(start + 1, buffer.position - start - 1);

Assim você elimina o MemoryBinaryOutput intermediário por mensagem e reduz objetos no GC. Para mensagens grandes, dá para ter caminho especial: flush do buffer atual e escrita direta do payload grande.

Também vale trocar ByteData.sublistView por escrita direta via shifts em SocketBinaryOutput e MemoryBinaryOutput. Hoje cada writeInt16, writeInt32, writeUint32, writeInt64 cria uma view ByteData temporária.

Prioridade: alta. Isso melhora muito microbenchmarks, batch/pipeline e qualquer carga com muitas queries pequenas.

3. Usar o TypeHandlerRegistry do conector, não criar um por reader

O NpgsqlConnector já tem um TypeHandlerRegistry próprio. Mas cada NpgsqlDataReaderImpl cria outro registry novo.

Isso é desperdício direto: cada reader registra todos os handlers novamente, inclusive handlers de JSON, geométricos, range, arrays etc. O TypeHandlerRegistry registra vários handlers no construtor.

Troque para:

class NpgsqlDataReaderImpl implements NpgsqlDataReader {
  NpgsqlDataReaderImpl(this._connector)
      : _typeRegistry = _connector.typeRegistry;

  final NpgsqlConnector _connector;
  final TypeHandlerRegistry _typeRegistry;
}

Prioridade: alta e fácil. É um ganho de alocação sem mudar protocolo.

4. Implementar PgRow/lazy decode de verdade

Hoje o parser cria um DataRowMessage por linha, com uma lista de Uint8List? por coluna. Depois, cada reader[index] resolve o handler e decodifica o valor naquele momento, mas se acessar a mesma coluna duas vezes, decodifica duas vezes.

O roadmap do próprio projeto já aponta isso: PgRow como view sobre buffer, acesso por índice/nome, lazy decode e menos alocações de string ainda estão pendentes.

O próximo passo seria transformar a linha em algo como:

final class PgRow {
  final Uint8List payload;
  final Int32List offsets;
  final Int32List lengths;
  final List<Object?>? decodedCache;

  Object? getValue(int index) {
    // decodifica só quando acessado
    // opcionalmente cacheia
  }
}

Para leitura sequencial de milhões de linhas, isso é muito mais importante que micro-otimizar SELECT 1. O Npgsql também chama atenção para modo sequencial e buffers quando rows grandes passam do buffer interno.

Prioridade: alta para SELECTs grandes. Para queries que retornam poucas linhas, o impacto é menor.

5. Evitar SqlRewriter no caminho quente

O SqlRewriter.rewrite() sempre varre a SQL e aloca StringBuffer, lista de parâmetros e mapa quando há parâmetros. Além disso, para cada @param, ele faz parameters.firstWhere(...), o que vira busca linear por placeholder.

O Npgsql documenta que placeholders posicionais nativos $1, $2 são preferíveis porque o PostgreSQL os entende diretamente; placeholders nomeados exigem parse/rewrite da SQL e têm custo de performance.

Otimizações práticas:

Se a SQL não contém @ nem ?, não rode o rewriter.
Se a SQL já usa $1, $2, pule rewrite.
Cacheie o plano de rewrite por SQL: SQL original → SQL reescrita + ordem dos nomes.
Crie Map<String, NpgsqlParameter> uma vez por command, não firstWhere por placeholder.
Corrija o parser para comments, dollar-quoted strings e casos PostgreSQL específicos, porque isso também evita rewrites errados.

Prioridade: alta para queries parametrizadas repetitivas.

6. Otimizar TypeHandlers: remover ByteData temporário e cópias em arrays

Vários handlers usam ByteData.sublistView no read e criam ByteData novo no write. Exemplos: IntegerHandler, FloatHandler, DoubleHandler, TimestampHandler, DateHandler.

No ArrayHandler, a leitura binária usa buffer.sublist(...), que copia bytes; isso deveria ser Uint8List.sublistView(...). A escrita de array também monta List<int> out, usa vários ByteData pequenos e só no fim cria Uint8List.fromList(out).

Troque isso por escrita direta em MemoryBinaryOutput ou, melhor ainda, no próprio buffer de Bind.

Prioridade: média/alta. Vai aparecer principalmente em arrays, bulk paramétrico e muitos valores numéricos.

7. Pipeline e batch já estão bons, mas ainda há riscos de backpressure

O projeto já avançou bastante em pipeline: fila de comandos pendentes, API pública, reader pipeline-aware, erro em pipeline, flush aggregation e testes reais aparecem no TODO/progresso.

O ponto agora não é “implementar pipeline”, e sim garantir que pipeline grande não vire acúmulo infinito de memória. A documentação do libpq alerta que pipeline melhora throughput, mas exige controle de fila, processamento FIFO dos resultados e cuidado para não cair em deadlock quando cliente e servidor produzem dados demais sem ler/escrever de forma intercalada.

Então eu adicionaria limites configuráveis:

maxPipelineCommands
maxPipelineBufferedBytes
maxInFlightBytes

E faria o pipeline intercalar flush/leitura quando passar do limite.

Prioridade: média. Para batch pequeno, já deve estar bom. Para pipeline massivo, isso vira essencial.

8. COPY streaming e cursors ainda podem dar ganhos grandes

O TODO mostra que COPY IN/OUT básico já existe, mas APIs stream-based, CSV/TEXT e progress callbacks ainda estão pendentes. Também estão pendentes cursors/fetch incremental com Stream<PgRow> e backpressure.

Para bulk insert/export, COPY é onde você mais se aproxima do teto real do PostgreSQL. Para SELECT enorme, cursor/fetch incremental evita carregar tudo em memória e conversa melhor com backpressure do Dart.

Prioridade: alta para ETL/import/export; média para APIs comuns.

O benchmark atual não prova teto

Seu benchmark atual compara dpgsql com o pacote postgres, mas o benchmark simples roda basicamente SELECT 1 em loop com executeReader() e drena o reader. O benchmark maior tem tipos de query como simple, select, where, join e aggregate, mas ainda não mede explicitamente auto-prepare, prepared cache, pipeline com tamanhos diferentes, COPY streaming, memória/GC ou latência artificial.

Isso é importante porque SELECT 1 local mede mais roundtrip + overhead fixo do driver do que throughput real. O próprio PostgreSQL/libpq documenta que pipeline é especialmente útil quando há muitas operações pequenas ou alta latência; quando a query demora muito no servidor, o ganho relativo do pipeline cai.

Eu criaria esta matriz mínima de benchmark:

Cenário	O que mede
SELECT 1 simple protocol	overhead mínimo/roundtrip
SELECT $1 extended sem prepare	custo Parse/Bind/Describe/Execute
SELECT $1 explicit prepare	ganho de prepared
auto-prepare após N usos	integração do manager
batch 10/100/1000 inserts	pipeline + writer buffer
pipeline 10/100/1000 selects	backpressure e ordering
SELECT 100k rows	parser/DataRow/PgRow/GC
SELECT rows largas com text/bytea	buffer e cópias
COPY IN 100k/1M rows	bulk throughput
COPY OUT 100k/1M rows	streaming/export
latência 1ms/10ms/50ms/100ms	benefício real de pipeline
Minha ordem recomendada
Benchmark e profiling primeiro: adicione medição de p50/p95/p99, ops/s, bytes alocados/op e GC. O próprio TODO ainda marca métricas, benchmarks comparativos, stress/load e profiling de memória como pendentes.
Quick wins de alocação: usar registry do conector no reader, sublistView em arrays, remover ByteData.sublistView em primitives, cachear _charCode/CStrings vazios.
Prepared cache real por conexão: esse é o item com maior chance de ganho em app real.
Writer contíguo com patch de length: reduz GC/syscalls/cópias em pipeline e batch.
PgRow/lazy decode: melhora muito SELECT grande.
COPY streaming e cursor streaming: melhora bulk e datasets grandes.
Multiplexing só depois: o TODO ainda lista multiplexing como baixa prioridade/avançado, e eu concordo.
Veredito

Não está no teto. Eu diria que o driver já tem uma arquitetura promissora, mas ainda há ganhos claros antes de falar em limite: prepared cache integrado, menos alocação no writer/parser, PgRow lazy, SQL rewrite cacheado, COPY/cursor streaming e benchmarks melhores. O “teto” só começa a ficar perto quando, em benchmarks com prepared + pipeline + COPY + baixa alocação, o tempo passar a ser dominado pelo PostgreSQL/rede e não pelo Dart/driver.


o foco é criar um driver postgresql de alto desempenho inspirado (portar) o npgsql para dart
C:\MyDartProjects\npgsql\referencias\npgsql-main

C:\MyDartProjects\dpgsql\referencias\npgsql

foque em ser mais proximo possivel da versão original npgsql ou seja mesmos nomes de classes, arquivos e metodos para facilitar diff
reponda sempre em portugues
continue portando o C:\MyDartProjects\npgsql\referencias\npgsql-main para dart e atualizando o C:\MyDartProjects\npgsql\TODO.md
não commita nada
use o comando rg para buscar no codigo fonte
use o comando timeout-cli 
timeout-cli.exe 30 dart test test\montgomery_fast_test.dart
referencias de implementação C:\MyDartProjects\dpgsql\referencias
implementar micro otimizações guiadas por benckmark

- [x] Implement text parsing for `NpgsqlInterval` (Postgres format).
- [x] Implement `NpgsqlParameter` properties (Precision, Scale, Size).
- [x] Implement Logical Replication Protocol (Messages, Parser, Connection, KeepAlive).
- [x] Implement Large Object Manager (`NpgsqlLargeObjectManager`, `NpgsqlLargeObjectStream`).
- [x] Implement Full-Text Search Types (`NpgsqlTsVector`, `NpgsqlTsQuery`).
- [x] Implement PreparedStatementManager for statement caching.
- [ ] Test Logical Replication against real server (Manual Verification required).
- [ ] Performance Tuning (Benchmark against other drivers).

Progresso 2025-04-12:
- Criado esqueleto de I/O binário: BinaryInput, SocketBinaryInput (buffer eficiente sem copiar tudo a cada leitura) e MemoryBinaryInput para testes.
... (keep existing history until line 141) ...

Progresso 2025-12-05 (Parte 17):
- **Connection String Builder**: Implementado `NpgsqlConnectionStringBuilder` e integrado à conexão.
- **Isolation Level**: Implementado enum e suporte em transações.
- **SSL Mode**: Refinado com `verifyCa` e `verifyFull`.
- **Refinements**: `NpgsqlDbType` adicionado e integrado a parâmetros/handlers.

Progresso 2025-12-05 (Parte 18):
- **Character Encoding**:
    - Adicionado suporte a `Encoding` na conexão (`clientEncoding`).
    - Propagação de `Encoding` para `TypeHandler` (leitura/escrita de textos, JSON, geométricos).
    - `FrontendMessages` e `NpgsqlConnector` atualizados para usar a codificação configurada.
- **Custom Types**:
    - Parsing de texto implementado para tipos Geométricos (`Point`, `Box`, `LSeg`, `Line`, `Path`, `Polygon`, `Circle`) em `geometric_handlers.dart`.
    - `TypeHandlerRegistry` atualizado para resolver tipos geométricos por valor e por tipo Dart.
    - `NpgsqlInterval` handler registrado (parsing de texto pendente).
- **Async Notifications**:
    - Exposto stream de notificações na `NpgsqlConnection`.
- **Prepared Statements**:
    - Suporte a placeholders `?` via `SqlRewriter`.

Progresso 2025-12-05 (Parte 19):
- **Interval Text Parsing**: Implementado parsing de formato texto padrão do Postgres (ex: "1 year 2 mons") para `NpgsqlInterval`.
- **NpgsqlParameter**: Adicionadas propriedades `precision`, `scale`, `size`.
- **Testes**: Adicionado grupo de testes para parsing de `NpgsqlInterval` em `test/types_test.dart`.
- **Logical Replication**:
    - Criado scaffold em `lib/src/replication`.
    - Implementado `NpgsqlReplicationConnection`.
    - Implementado `LogicalReplicationProtocol` (Messages: Begin, Commit, Relation, Insert, Update, Delete) e `ReplicationMessageCode`.
    - Atualizado `BinaryInput` com `readInt64` para suportar LSNs e Timestamps.

Progresso 2025-12-07 (Parte 20):
- **Large Object Manager**: Implementado suporte completo para Large Objects PostgreSQL.
    - `NpgsqlLargeObjectManager`: Gerenciamento de Large Objects (create, open, unlink, import/export).
    - `NpgsqlLargeObjectStream`: Stream para leitura/escrita de Large Objects (read, write, seek, setLength).
- **Full-Text Search Types**: Implementados tipos para busca textual PostgreSQL.
    - `NpgsqlTsVector`: Representação de tsvector (lexemas com posições e pesos).
    - `NpgsqlTsQuery`: Representação de tsquery (Lexeme, Not, And, Or, FollowedBy nodes).
- **Prepared Statement Management**: Implementado `PreparedStatement` e `PreparedStatementManager`.
    - Gerenciamento de cache de prepared statements (explícitos e auto-prepare).
    - Suporte a LRU eviction para auto-prepared statements.
- **Refinements**: 
    - Integrado `NpgsqlDataSource` com `NpgsqlConnectionStringBuilder`.
    - Adicionado método `getValue` em `NpgsqlDataReader`.
    - Corrigidos todos os warnings de análise estática (9 issues resolvidos).
    - Atualizado `lib/dpgsql.dart` com exports de Large Objects, TsVector, TsQuery e Replication.

Progresso 2025-12-07 (Parte 21 - Current):
- **Schema Metadata**: Implementado `NpgsqlDbColumn` para metadados de schema.
    - Suporte completo a propriedades padrão do .NET DbColumn.
    - Campos específicos do PostgreSQL (typeOid, tableOid, columnAttributeNumber, defaultValue).
    - Método `clone()` para cópia de instâncias.
    - Operador `[]` para acesso a propriedades por nome.
- **Testes**: Todos os 63 testes passando (2 skipped por mocks incompletos).
- **Qualidade**: `dart analyze` - No issues found! ✅

Progresso 2025-12-08 (Parte 22):
- **Buffering**: `WriteBuffer` ganhou `hasPending`, espelhando o controle de fila do Npgsql e permitindo flush condicional no writer.
- **PostgresMessageWriter**: Removidas `!` redundantes e promovido uso de buffer seguro, alinhando com padrões null-safe.
- **Type Handlers**: Limpeza em `TimestampHandler` (remoção de campo não utilizado) mantendo lógica de epoch local.
- **Testes**: Removido helper `_usageExample` que dependia de banco real, deixando `timezone_encoding_test.dart` focado em validações determinísticas.
- **Qualidade**: `dart analyze` continua sem issues.

Progresso 2025-12-08 (Parte 23):
- **Pipeline Buffering**: `PostgresMessageWriter` agora dispara `flushIfNeeded()` para buffers grandes, replicando a política de coalescência do Npgsql e evitando estouro de memória.
- **API Writer**: Exposto método `flushIfNeeded()` público para cenários que controlam flush manual (pipeline, batches).
- **Binary I/O**: `BinaryOutput` recebe `writeUint16/Uint32`, `BinaryInput` ganha `readUint16/Uint32` (incluindo `_CopyStreamBinaryInput`), permitindo suportar OIDs acima de 2³¹.
- **Perf Writer**: `PostgresMessageWriter` reutiliza buffer interno (scratch), evita alocações por mensagem e protege contra uso concorrente.
- **Testes**: Coberto `writeParse` com OID uint32 em `frontend_messages_test.dart`.
- **Qualidade**: `dart analyze` segue limpo.

Progresso 2025-12-08 (Parte 24):
- **Pipeline Queue**: `readMessage()` agora sincroniza a fila de `PendingCommand`, marca comandos apenas após `CommandComplete` e realiza auto `exitPipelineMode()` quando `ReadyForQuery` chega.
- **Batch Pipeline**: `executeQueryPipelined` ficou assíncrono, garante envio sequencial e `pipelineSync()` passou a apenas disparar o `Sync` + flush, evitando consumir respostas do leitor.
- **Pooling**: `_healthCheck` e `_resetConnection` usam timeouts curtos (100ms), prevenindo hangs com servidores mock e mantendo reaproveitamento de conexões.
- **Testes**: `batch_test.dart`, `datasource_pool_test.dart` e `datasource_test.dart` agora passam sem timeouts; suíte completa `dart test` ✅.

Progresso 2025-12-08 (Parte 25):
- **Writer Buffer**: `NpgsqlConnector` cria `PostgresMessageWriter` com buffer de 16 KB, garantindo coalescência automática semelhante ao Npgsql original.
- **Pipeline Flush**: `flushPipeline()` e `pipelineSync()` usam `PostgresMessageWriter.flush()`; Sync agora respeita a fila antes de enviar ao socket, evitando flush redundante.
- **Estabilidade**: Pipeline mantém ordenação com `flushIfNeeded` e segue passando toda a suíte de testes (`dart test`).

Progresso 2025-12-08 (Parte 26):
- **Pipeline Errors**: `_processPipelineMessage` propaga `ErrorResponse` para a fila inteira (`clear` + falha dos comandos restantes) e força saída automática do modo pipeline ao receber `ReadyForQuery`.
- **Recuperação**: `_handleReadyForQueryMessage` aplica erro pendente ao encerrar a fila, garantindo que `exitPipelineMode()` aconteça mesmo após aborts.
- **Testes**: `batch_test.dart` ganhou cenário simulando `ErrorResponse` em pipeline (mock server), validando que a conexão se recupera e lança `PostgresException` com mensagem.

Progresso 2025-12-09 (Parte 27):
- **Streaming de Pipeline**: `PendingCommand` agora guarda mensagens em fila interna e expõe `takeMessage()`, permitindo consumo incremental sem interleaving.
- **DataReader Pipeline-aware**: `NpgsqlDataReaderImpl` passou a consumir comandos via `readMessageForPending`, alternando entre comandos pipelined e mensagens globais (`ReadyForQuery`), com suporte a `NoData`.
- **Batch Pipelined**: `executeBatch` coleta os `PendingCommand` emitidos e injeta no reader para permitir streaming sequencial de múltiplos comandos.
- **Resiliência**: `PendingCommand` evita erros assíncronos não tratados ao fechar `StreamController`/`Completer`, e `NpgsqlConnector` ganhou helper `readMessageForPending` para bombear o socket sob demanda.
- **Testes**: `batch_test.dart` roda íntegro com o novo fluxo; restante da suíte `dart test` continua passando.

Progresso 2025-12-09 (Parte 28):
- **API Pipeline Pública**: `NpgsqlConnection` expõe `executeQueryPipelined`, `flushPipeline` e criadores de reader (`getPipelineReader`, `getPipelineReaderForCommands`), permitindo consumo ordenado dos `PendingCommand` externos.
- **Reader Configurável**: `NpgsqlDataReaderImpl` ganhou flag `drainReadyOnClose`, evitando deadlocks quando múltiplos readers consomem mesma barreira.
- **Connector Helpers**: `NpgsqlConnector.createPipelineReader` aceita múltiplos comandos e controla o dreno de ReadyForQuery; variante single-command retorna sem aguardar `ReadyForQuery`.
- **Teste de Integração**: `pipeline_mode_test.dart` agora valida fluxo completo (handshake, pipeline com dois SELECTs, leitura sequencial de resultados e encerramento).

Progresso 2025-12-09 (Parte 29):
- **Draining Pós-Erro**: `_processPipelineMessage` liga `_pipelineDrainingAfterError` após `ErrorResponse`, e `readMessage()` passou a descartar mensagens protocolares até o próximo `ReadyForQuery`, garantindo alinhamento com o Sync/Reset do servidor.
- **ReadyForQuery Cleanup**: `_handleReadyForQueryMessage` desarma a drenagem e limpa pendentes com a exceção propagada, prevenindo vazamento de comandos falhos.
- **Testes**: `batch_test.dart` agora injeta mensagens extras após erro para validar o descarte, e toda a suíte (`dart test`) permanece verde.

Progresso 2025-12-09 (Parte 30):
- **Pipeline via NpgsqlCommand**: `executeCommandsPipelined` monta e sincroniza pipelines a partir de uma lista de `NpgsqlCommand`, com auto `enterPipelineMode` e saída programada via `ReadyForQuery`.
- **Planos de Execução**: `NpgsqlCommand` gera `NpgsqlCommandExecutionPlan`, reutilizado tanto em execuções imediatas quanto pipelined (com reescrita de parâmetros e prepared statements).
- **Utilities do Conector**: Expostos helpers para agendar saída automática, cancelar e abortar pipelines (limpando filas e estados internos).
- **Teste**: `pipeline_mode_test.dart` ganhou cenário cobrindo pipeline com `NpgsqlCommand` e parâmetros nomeados.

Progresso 2025-12-09 (Parte 31):
- **Validação Real**: `real_pipeline_test.dart` conecta em PostgreSQL real e cobre `executeCommandsPipelined` misturando comandos preparados e ad-hoc.
- **Concorrência**: Teste estressa quatro conexões em paralelo, garantindo que pipelines independentes não vazam estado (`inPipelineMode` limpa ao final).
- **Expectativas Precisando**: Casos validam retornos de `array_agg` para `List<int>` e fallback string, incluindo parsing para garantir valores corretos.
- **Infra**: Novos helpers do conector reutilizados em `executeBatch` para padronizar auto-exit/cancel de pipeline.

Progresso 2025-12-09 (Parte 32):
- **Buffer Aggregation**: `executeQueryPipelined` agora monitora bytes/mensagens no `WriteBuffer` e força flush oportuno (>= maxBufferSize ou 16 mensagens), reduzindo syscalls sem atrasar respostas.
- **Describe Controlado**: `FrontendMessages.writeDescribePortal/Statement` recebeu parâmetro `flush`, permitindo sequências Parse/Bind/Describe/Execute compactadas.
- **Verificação**: Testes `pipeline_mode_test.dart`, `real_pipeline_test.dart` e a suíte completa `dart test` foram executados após a otimização, garantindo estabilidade.
- **Roadmap**: Item "Otimização de flush (buffer aggregation)" marcado como concluído.

Progresso 2025-12-09 (Parte 33):
- **SocketBinaryInput**: `_consume` reescrito para acessar o buffer via `ByteData` reutilizável, evitando alocações temporárias a cada leitura multi-byte.
- **Compaction**: `_appendData` agora realinha dados não lidos no próprio buffer quando há capacidade, reduzindo realocações e cópias de grandes blocos.
- **Leitura Raw**: `readBytes` passou a retornar views (`Uint8List.sublistView`) sobre o buffer interno, mantendo zero-copy para consumidores de payload binário.
- **Testes**: `dart test` completo executado com sucesso (`00:07 +81 ~2: All tests passed!`).

Progresso 2025-12-09 (Parte 34):
- **Batch Errors**: `PostgresBatchException` criado para relatar falhas parciais com snapshot dos comandos e índice da falha.
- **Comandos**: `NpgsqlBatchCommand` registra exceção associada e `PendingCommand` propaga sucesso/erro para o comando correspondente.
- **Reader**: `NpgsqlDataReaderImpl` converte `ErrorResponse` em `PostgresBatchException`, preservando resultados prévios ao erro.
- **Pooling**: `SocketBinaryInput` passou a alocar buffers via `Uint8ListPool`, liberando-os no fechamento da conexão.
- **Testes**: `batch_test.dart` valida exceção agregada e estado dos comandos; suíte `dart test` executada com sucesso (`00:09 +81 ~2: All tests passed!`).


o foco é criar um driver postgresql de alto desempenho inspirado (portar) o npgsql para dart C:\MyDartProjects\npgsql\referencias\npgsql-main foque em ser mais proximo possivel da versão original npgsql ou seja mesmos nomes de classes, arquivos e metodos para facilitar diff reponda sempre em portugues continue portando o C:\MyDartProjects\npgsql\referencias\npgsql-main para dart e atualizando o C:\MyDartProjects\npgsql\TODO.md

use o comando rg para buscar no codigo fonte

referencias de implementação C:\MyDartProjects\dpgsql\referencias

Progresso 2025-04-12:

Criado esqueleto de I/O binário: BinaryInput, SocketBinaryInput (buffer eficiente sem copiar tudo a cada leitura) e MemoryBinaryInput para testes.
Adicionado BinaryOutput: SocketBinaryOutput com buffer e flush para IOSink/Socket; MemoryBinaryOutput para testes/payload em memória.
Criados testes unitários para leitura/escrita (MemoryBinaryInput/Output e SocketBinaryInput/Output com sockets locais).
Adicionada camada simples de mensagens do protocolo: PostgresMessage + PostgresMessageReader/Writer (tipo + length + payload) e testes.
Implementadas mensagens de frontend: SSLRequest, StartupMessage e Query; testes cobrindo geração de bytes.
Acrescentadas mensagens de frontend para Parse, Bind, Describe (statement/portal), Execute, Sync e Terminate, com testes unitários validando payloads.
Implementadas mensagens de backend (Authentication, ParameterStatus, ReadyForQuery, BackendKeyData, RowDescription, DataRow, CommandComplete, Copy, Error/Notice) e o BackendMessageReader que converte PostgresMessage em tipos fortes usando BinaryInput.
Adicionados testes de backend cobrindo ReadyForQuery, ParameterStatus, Authentication MD5, RowDescription, DataRow e ErrorResponse.
Próximos passos:

Integrar essa camada com o parser de mensagens do protocolo PostgreSQL (ler mensagem inteira e delegar parsing para um MemoryBinaryInput).
Adicionar testes adicionais de erro (SocketBinaryInput com onError) e cenários de flush parcial/fragmentado se necessário.
Integrar com estado de conexão (handshake completo, autenticação, troca de parâmetros) e iniciar camada de pooling.
Amarrar BackendMessageReader ao fluxo de conexão (autenticação MD5/SASL, ParameterStatus, BackendKeyData, ReadyForQuery).
Implementar tratamento rico de Error/Notice (mapear para exceções), NotificationResponse e caminhos de Copy/FunctionCall que ainda não têm consumidor.
Progresso 2025-12-05:

Implementado NpgsqlConnector (lib/src/internal/npgsql_connector.dart) gerenciando Socket.
Integrado PostgresMessageReader e BackendMessageReader no fluxo de conexão.
Implementado Handshake (StartupMessage, ParameterStatus, BackendKeyData, ReadyForQuery).
Implementada Autenticação (Cleartext e MD5 usando pointycastle).
Progresso 2025-12-05 (Parte 2):

Implementado tratamento rico de Error/Notice (PostgresException) mapeando campos do ErrorResponse.
Criada API pública NpgsqlConnection e NpgsqlCommand.
Implementado NpgsqlDataReader e suporte a Query Simples (executeReader).
Testes integrados de Handshake, Autenticação e Simple Query (Mock Server).
Progresso 2025-12-05 (Parte 3):

Implementado suporte básico ao Extended Query Protocol (Parse, Bind, Describe, Execute, Sync).
Adicionados NpgsqlParameter e NpgsqlParameterCollection para suportar queries parametrizadas.
Atualizado NpgsqlDataReader para coexistir com mensagens de Extended Query (ParseComplete, BindComplete).
Teste de integração de Query Estendida (Mock Parse/Bind flow).
Progresso 2025-12-05 (Parte 4):

Implementado NpgsqlDataSource com suporte básico a Pooling de Conexões.
Refatorado NpgsqlConnection para aceitar conectores existentes (fromConnector).
Teste de integração verificando reuso de conexões (pooling).
Progresso 2025-12-05 (Parte 5):

Type Handlers Implementados: TypeHandler, TypeHandlerRegistry, Oid. Suporte a Text, Integer, Bool.
NpgsqlDataReader decodifica valores usando handlers quando em formato binário.
NpgsqlConnector usa handlers para serializar parâmetros binários e requisita resultados em binário.
SCRAM-SHA-256 Implementado: Criado ScramSha256Authenticator e integrado ao fluxo de conexão.
Cancelamento Implementado: Adicionado cancel() em NpgsqlConnection e cancelRequest() em NpgsqlConnector (abre nova conexão temporária).
Progresso 2025-12-05 (Parte 6):

Novos Type Handlers: Adicionados Float4 (FloatHandler), Float8 (DoubleHandler), Timestamp, Date, Bytea (Uint8List).
Pooling Melhorado: NpgsqlDataSource agora verifica se a conexão está conectada (isConnected) antes de retorná-la do pool.
Testes de Tipos Binários: Criado test/binary_types_test.dart simulando resposta binária para Inteiros e validando decodificação.
IsConnected: Exposto getter em NpgsqlConnector.
Progresso 2025-12-05 (Parte 7):

Arrays Implementados: Adicionado ArrayHandler<E> no TypeHandler. Todos os tipos básicos agora têm suporte a Arrays (int[], text[], etc). resolveByValue detecta listas.
Transações Implementadas: Criado NpgsqlTransaction com suporte a commit() e rollback().
COPY Proto: Adicionadas mensagens de Frontend CopyData, CopyDone, CopyFail.
Progresso 2025-12-05 (Parte 9):

API de COPY (Binary Import): Implementado beginBinaryImport em NpgsqlConnection e classe NpgsqlBinaryImporter.
Protocolo COPY: Suporte a mensagens CopyData, CopyDone, CopyFail, CopyInResponse no NpgsqlConnector.
Sincronização de Protocolo: Ajustado awaitCopyComplete para consumir ReadyForQuery, corrigindo bug de sincronia em Simple Query mode.
Teste Real COPY: test/real_copy_test.dart criado e passando com sucesso (Insert via COPY + Select verification).
Progresso 2025-12-05 (Parte 10):

Refinamento de COPY:
Corrigidos erros de compilação em NpgsqlBinaryImporter e NpgsqlBinaryExporter (imports, tipos).
Adicionado resolveByDartType<T> no TypeHandlerRegistry para permitir inferência de handler pelo tipo genérico Dart.
NpgsqlBinaryExporter refatorado para usar TypeHandler na leitura (read<T>), suportando nativamente int, String, bool, double, DateTime, Uint8List.
Leitura e análise do roteiro_performace.md, confirmando foco em Extended Protocol e Pipeline como próximos grandes passos.
Progresso 2025-12-05 (Parte 11):

COPY Export Finalizado:
Criado teste de integração test/real_copy_export_test.dart validando COPY TO STDOUT com tipos int, text, float8 e NULL.
Corrigido bug crítico em NpgsqlBinaryExporter onde inteiros lidos do stream não eram tratados como signed (causando falha em ensureBytes com valores negativos/grandes).
Limpeza de código e imports em NpgsqlBinaryExporter, NpgsqlBinaryImporter e NpgsqlDataReaderImpl.
dart analyze lib limpo (sem erros/warnings).
Progresso 2025-12-05 (Parte 12):

Prepare() Implementado:
Adicionado método prepare() em NpgsqlCommand, NpgsqlConnection e NpgsqlConnector.
Implementado fluxo de Parse + Describe Statement + Sync no prepare.
Atualizado executeReader para usar Bind com statementName quando preparado, pulando o Parse.
Criado teste de integração test/prepare_test.dart validando reutilização de statement preparado com diferentes parâmetros.
Nota: O suporte a @param ainda não existe (requer reescrita de SQL), testes usam $1.
Progresso 2025-12-05 (Parte 13):

SQL Rewriting Implementado:
Criada classe SqlRewriter em lib/src/internal/sql_rewriter.dart para converter parâmetros nomeados (@param) para posicionais ($1, $2).
Integrado SqlRewriter em NpgsqlCommand.prepare() e executeReader().
Atualizado test/prepare_test.dart para usar @id, validando a reescrita automática e o mapeamento de parâmetros.
Suporte a Prepared Statements agora é completo e amigável (estilo Npgsql).
Progresso 2025-12-05 (Parte 14):

SSL/TLS Support:
Implementado SslMode (Disable, Prefer, Require, Allow) e handshake SSL em NpgsqlConnector.
Suporte a upgrade para SecureSocket.
Teste de handshake SSL (test/ssl_test.dart) cobrindo cenários de fallback e erro.
Text Parsing:
Atualizado TypeHandler para suportar leitura de formato texto (isText: true).
Atualizado NpgsqlDataReaderImpl para usar handlers com flag isText quando o formato da coluna é texto (Simple Query Protocol).
Implementado parsing de texto para tipos básicos (int, double, bool, DateTime).
Novos Tipos:
JSON/JSONB: Implementados JsonHandler e JsonbHandler (leitura/escrita UTF8 e versão binary JSONB).
Geometric Types: Implementados Point, Box, Line, LSeg, Path, Polygon, Circle e seus handlers.
Range Types: Implementado NpgsqlRange<T> e RangeHandler<T> genérico. Suporte a int4range, int8range, numrange, tsrange, tstzrange, daterange.
Criado test/types_test.dart validando serialização/deserialização desses novos tipos.
Next Steps
Authentication Mechanisms:
Implement SCRAM-SHA-256 verification (server signature).
Implement GSSAPI/Kerberos (Low priority).
Pipeline Mode:
Implement explicit pipeline mode API (NpgsqlDataSource.createBatch is implicit pipeline, but explicit EnterPipelineMode might be needed for advanced usage).
Replication:
Implement Logical Replication Protocol (Low priority).
Performance Tuning:
Benchmark against other drivers.
Optimize buffer usage.

## 🎯 ROADMAP - Funcionalidades Pendentes

### ⚡ Alta Prioridade (Performance Crítica)

**1. Pipeline Mode (Protocolo Estendido Avançado)** ⚙️ **EM ANDAMENTO**
- [x] Implementar fila de comandos pendentes (PipelineCommandQueue)
- [x] Estrutura básica de PendingCommand com estado e tracking
- [x] API básica: enterPipelineMode / exitPipelineMode / pipelineSync
- [x] Método executeQueryPipelined para envio sem await
- [x] _sendQueryMessages para envio de Parse/Bind/Execute sem flush
- [x] Tratamento completo de respostas em pipeline (DataRow streaming)
- [x] Reader pipeline-aware consumindo PendingCommand (createPipelineReader)
- [x] Gestão completa de erro em pipeline (ErrorResponse + descarte até próximo Sync)
- [x] Integração com NpgsqlCommand para pipeline automático
- [x] Otimização de flush (buffer aggregation)

**2. Batch API Completo**
- [x] NpgsqlBatch básico (existente mas precisa integração com pipeline)
- [x] Executar batch usando pipeline internamente
- [x] executeBatchPipelined() convenience method
- [x] flushPipeline() para buffer aggregation
- [x] Mapear respostas individuais de cada comando no batch
- [x] Tratamento de erros parciais em batch
- [ ] Suporte a múltiplos result sets por batch

**3. Prepared Statement Cache Avançado**
- [x] PreparedStatementManager básico (implementado)
- [x] Auto-prepare após N execuções (threshold configurável)
- [x] LRU tracking (lastUsed timestamp)
- [x] Métricas de hit/miss do cache
- [x] LRU eviction quando cache atinge limite
- [ ] Integração com pool de conexões (cache por conexão)

**4. Pool de Conexões Robusto**
- [x] Pool básico em NpgsqlDataSource (implementado)
- [x] Reset de estado no checkout (rollback transações abertas)
- [x] Limpar prepared statements/portals órfãos (DISCARD ALL)
- [x] Health check de conexões antes de retornar do pool
- [x] Métricas de pool (conexões ativas, idle, tempo de espera)
- [x] Maximum Pool Size com fila de espera
- [x] Timeout de checkout quando pool está esgotado
- [x] Connection warmup (pre-create connections)
- [x] Idle/lifetime pruning no checkout/return
- [x] Pruning periódico em background
- [x] Detecção de reader/transaction aberta antes de devolver ao pool
- [ ] Detecção de COPY import/export aberto antes de devolver ao pool

### 📊 Média Prioridade (Funcionalidades Importantes)

**5. I/O Otimizado**
- [x] SocketBinaryInput com buffer (implementado)
- [x] Eliminar cópias desnecessárias em _consume
- [ ] Buffer de escrita agregado (acumular mensagens antes de flush)
- [ ] flush() controlado para batching
- [x] Reuso de Uint8List/ByteData (object pooling)

**6. Representação de Dados Eficiente**
- [x] PgRow com view sobre buffer (sem Map por linha)
- [x] Acesso por índice (`row[0]`) e por nome (`row.getByName('col')`)
- [x] Decodificação lazy (só quando acessado)
- [x] Minimizar alocações de String para colunas numéricas no caminho `executePgRows`
- [x] API streaming/callback para processar `PgRow` sem copiar payload para lista materializada (`forEachPgRow`)
- [ ] `foldPgRows`/agregadores especializados para leituras de altissima vazao

**7. COPY Avançado**
- [x] COPY IN/OUT básico (implementado)
- [ ] Stream-based API para COPY IN
- [ ] Stream-based API para COPY OUT  
- [ ] Suporte a COPY com formato CSV/TEXT
- [ ] Progress callbacks para bulk operations

**8. Cursors e Fetch Incremental**
- [ ] DECLARE CURSOR
- [ ] FETCH FORWARD/BACKWARD
- [ ] API Stream<PgRow> com backpressure
- [ ] CLOSE CURSOR automático

### 🚀 Baixa Prioridade (Funcionalidades Avançadas)

**9. Multiplexing (Npgsql-style)**
- [ ] Sessões lógicas multiplexadas
- [ ] Fila sofisticada de comandos
- [ ] Backpressure e fairness
- [ ] Concorrência de queries em uma conexão física

**10. Classes Npgsql Faltantes**
- [ ] NpgsqlDataAdapter (ADO.NET compatibility)
- [ ] NpgsqlCommandBuilder (auto-gerar INSERT/UPDATE/DELETE)
- [ ] NpgsqlMetricsOptions (observability)
- [ ] NpgsqlLoggingConfiguration (structured logging)
DataTable

**11. Melhorias de Protocol**
- [x] Extended Query Protocol básico (implementado)
- [ ] Portal reuse para múltiplos Execute
- [ ] Describe Portal (além de Describe Statement)
- [ ] Close Statement/Portal explícito

**12. Type Handlers Avançados**
- [x] Tipos básicos, Arrays, JSON, Geometric, Range (implementados)
- [ ] Composite Types (ROW)
- [ ] Enum Types
- [ ] Domain Types
- [ ] User-Defined Types (UDT) via plugins

### 🔧 Micro-Otimizações

- [ ] Formato binário prioritário para todos os tipos (atualmente misto)
- [ ] Fast paths para queries muito comuns (SELECT 1, simple lookups)
- [ ] Evitar `dynamic` em hot paths
- [ ] Reusar TypeHandler instances (singleton pattern)
- [ ] String interning para nomes de colunas/tabelas

### 📝 Observabilidade e Testing

- [ ] Métricas de performance (latency, throughput)
- [ ] Benchmarks comparativos (vs postgres, etc)
- [ ] Testes de stress/load
- [ ] Profiling de memória
- [ ] Tracing/spans para queries (OpenTelemetry)

---

**Status Atual**: ~70% do core implementado, pronto para uso básico/intermediário.
**Próximo Marco**: Pipeline Mode + Batch otimizado = 90% performance do Npgsql C#.

hecklist curto e direto do que precisa pra ficar realmente rápido.

Vou separar em “coisas que dão ganho grande” e “micro-otimizações”.

1. Funcionalidades que dão ganho grande (prioridade alta)
1.1. Protocolo estendido bem feito (base de tudo)

Implementar de verdade o extended query protocol:

Parse / Bind / Describe / Execute / Sync.

Reuso de prepared statements:

Cache por conexão de statementName → SQL / tipos.

Evitar mandar Parse toda vez se o SQL é igual.

Reuso de portals quando fizer sentido (pelo menos entender bem o ciclo de vida).

Suporte a formato binário para tipos comuns (int, float, timestamp, uuid) para reduzir texto/parsing.

Sem isso, pipeline/batch já nascem capados.

1.2. Pipeline mode (estilo libpq)

Sim, isso é core pra alta performance:

Permitir mandar várias sequências Parse/Bind/Execute seguidas sem esperar resposta entre elas.

Tratar o Sync como barreira (ponto onde você sabe que todas as respostas anteriores chegaram).

Manter uma fila de “comandos pendentes”:

Cada item da fila sabe quantas mensagens de resposta esperar.

Conforme você lê as mensagens, vai marcando o comando como completo.

Tratar erros de forma correta:

Quando der erro em uma mensagem, o servidor manda ErrorResponse + ReadyForQuery.

Tudo depois do erro até o próximo Sync é “descartado” internamente, você tem que sincronizar o estado do client.

Com isso você ganha:

Menos round-trips em cenários de muitas queries pequenas;

Latência escondida (overlap de execução no servidor + leitura de rede).

1.3. Batching (estilo Npgsql)

Em cima do pipeline, você expõe uma API tipo:

PgBatch / PgCommandBatch / algo assim:

batch.add("INSERT ...", params),

batch.add("UPDATE ...", params),

await batch.execute();

Internamente:

Você simplesmente monta um pipeline com todos esses comandos.

Mapeia as respostas de volta para cada “entry” do batch.

Ganhos:

O usuário não precisa pensar em pipeline explícito.

Ele só fala “quero mandar esses N comandos juntos”.

1.4. Pool de conexões + reuso

Alta performance em app real = pool:

Manter conexões reutilizáveis;

Reset leve de estado no checkout (rollback se tiver transação aberta, limpar parâmetros/portais);

Evitar custo de handshake/TLS/auth toda hora.

Em cima disso:

Cache de prepared statements por conexão (não global!).

Se quiser ser mais agressivo, pode ter um cache lógico global que “ensina” conexões novas a preparar statements comuns, mas isso já é luxo.

1.5. COPY para bulk

Pra INSERT de grandes volumes:

Implementar COPY IN / OUT:

COPY ... FROM STDIN,

COPY ... TO STDOUT.

Oferecer uma API de stream:

Stream<List<int>> ou Stream<Row> → COPY IN,

COPY OUT → Stream<Row> ou de chunks binários.

Isso dá um ganho brutal em:

importação de dados,

ETL,

migrações pesadas.

2. Coisas de arquitetura/perf de rede (importantes também)
2.1. I/O eficiente (BinaryInput/BinaryOutput)

Um buffer de leitura por conexão (tipo o SocketBinaryInput que falamos, ajustado pra não copiar tudo a cada _consume).

Um buffer de escrita:

Acumula várias mensagens em Uint8List interno,

Dá um socket.add() só com chunk grande,

flush() controlado (bem útil em pipeline).

Objetivo:

Poucas cópias de memória,

Poucos add() no socket,

Sem await a cada pequena mensagem.

2.2. Representação de linha/resultado leve

Evitar:

Criar Map<String, dynamic> por linha com milhões de alocações.

Melhor:

Uma classe PgRow que é view em cima de um buffer:

Indexado por posição (row[0], row[1]),

Optionally por nome (row['col']) com um map de nomes → índice,

Decodificação “sob demanda” quando o campo é acessado.

3. Coisas avançadas / nice-to-have (para ir além)
3.1. Multiplexing (estilo Npgsql multiplexing)

Super avançado, mas poderoso:

Várias “sessões lógicas” dentro de uma conexão física.

O driver interleia comandos de vários usuários/conexões lógicas no mesmo socket.

Você precisa de:

Uma fila mais sofisticada de comandos,

Gestão de backpressure e fairness.

Isso aumenta muito o throughput em cenários de muitas queries pequenas, mas é um passo bem além de pipeline/batch.

3.2. Cursors / fetch incremental

Para queries que retornam muitos dados:

Suporte a cursors/portals com FETCH:

Em vez de puxar tudo de uma vez, você faz FETCH n em loop.

API de Stream<PgRow>:

Controla quantos dados mantêm em memória,

Integra com backpressure do Dart.

4. Micro-otimizações que ajudam mas não são “game changers”

Usar formato binário sempre que possível para tipos numéricos / timestamp.

Minimizar String allocations (principalmente para colunas numéricas).

Reusar buffers (Uint8List/ByteData) em vez de criar novos o tempo todo.

Evitar dynamic em hot paths (tipos bem definidos, genéricos se precisar).

Ter caminhos rápidos para casos muito comuns:

SELECT 1,

SELECT col1,col2 FROM tabela WHERE pk = $1.

Resumão em uma frase

Para alta performance real no seu driver PostgreSQL em Dart, além de implementar Pipeline mode (estilo libpq) e Batching (estilo Npgsql), você precisa:

Extended protocol bem feito + cache de prepared + pool de conexões + I/O bufferizado eficiente + (opcionalmente) COPY, cursors, e quem sabe multiplexing no futuro.

Se quiser, no próximo passo posso montar um mini “roadmap” em checklist (MVP → alta performance → features avançadas) só pro driver que você está fazendo.
