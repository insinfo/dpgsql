o foco é criar um driver postgresql de alto desempenho inspirado (portar) o npgsql para dart
C:\MyDartProjects\npgsql\referencias\npgsql-main
foque em ser mais proximo possivel da versão original npgsql ou seja mesmos nomes de classes, arquivos e metodos para facilitar diff
reponda sempre em portugues
continue portando o C:\MyDartProjects\npgsql\referencias\npgsql-main para dart e atualizando o C:\MyDartProjects\npgsql\TODO.md

use o comando rg para buscar no codigo fonte
timeout-cli.exe 30 dart test test\montgomery_fast_test.dart
referencias de implementação C:\MyDartProjects\dpgsql\referencias

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
- [ ] Tratamento completo de respostas em pipeline (DataRow streaming)
- [ ] Gestão completa de erro em pipeline (ErrorResponse + descarte até próximo Sync)
- [ ] Integração com NpgsqlCommand para pipeline automático
- [ ] Otimização de flush (buffer aggregation)

**2. Batch API Completo**
- [x] NpgsqlBatch básico (existente mas precisa integração com pipeline)
- [x] Executar batch usando pipeline internamente
- [x] executeBatchPipelined() convenience method
- [x] flushPipeline() para buffer aggregation
- [ ] Mapear respostas individuais de cada comando no batch
- [ ] Tratamento de erros parciais em batch
- [ ] Suporte a múltiplos result sets por batch

**3. Prepared Statement Cache Avançado**
- [x] PreparedStatementManager básico (implementado)
- [x] Auto-prepare após N execuções (threshold configurável)
- [x] LRU tracking (lastUsed timestamp)
- [x] Métricas de hit/miss do cache
- [ ] LRU eviction quando cache atinge limite
- [ ] Integração com pool de conexões (cache por conexão)

**4. Pool de Conexões Robusto**
- [x] Pool básico em NpgsqlDataSource (implementado)
- [ ] Reset de estado no checkout (rollback transações abertas)
- [ ] Limpar prepared statements/portals órfãos
- [ ] Health check de conexões antes de retornar do pool
- [ ] Métricas de pool (conexões ativas, idle, tempo de espera)
- [ ] Connection warmup (pre-create connections)

### 📊 Média Prioridade (Funcionalidades Importantes)

**5. I/O Otimizado**
- [x] SocketBinaryInput com buffer (implementado)
- [ ] Eliminar cópias desnecessárias em _consume
- [ ] Buffer de escrita agregado (acumular mensagens antes de flush)
- [ ] flush() controlado para batching
- [ ] Reuso de Uint8List/ByteData (object pooling)

**6. Representação de Dados Eficiente**
- [ ] PgRow com view sobre buffer (sem Map por linha)
- [ ] Acesso por índice (row[0]) e por nome (row['col'])
- [ ] Decodificação lazy (só quando acessado)
- [ ] Minimizar alocações de String para colunas numéricas

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