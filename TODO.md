o foco é criar um driver postgresql de alto desempenho inspirado (portar) o npgsql para dart
C:\MyDartProjects\npgsql\referencias\npgsql-main
foque em ser mais proximo possivel da versão original npgsql ou seja mesmos nomes de classes, arquivos e metodos para facilitar diff
reponda sempre em portugues
continue portando o C:\MyDartProjects\npgsql\referencias\npgsql-main para dart e atualizando o C:\MyDartProjects\npgsql\TODO.md

use o comando rg para buscar no codigo fonte

referencias de implementação C:\MyDartProjects\dpgsql\referencias

Progresso 2025-04-12:
- Criado esqueleto de I/O binário: BinaryInput, SocketBinaryInput (buffer eficiente sem copiar tudo a cada leitura) e MemoryBinaryInput para testes.
- Adicionado BinaryOutput: SocketBinaryOutput com buffer e flush para IOSink/Socket; MemoryBinaryOutput para testes/payload em memória.
- Criados testes unitários para leitura/escrita (MemoryBinaryInput/Output e SocketBinaryInput/Output com sockets locais).
- Adicionada camada simples de mensagens do protocolo: PostgresMessage + PostgresMessageReader/Writer (tipo + length + payload) e testes.
- Implementadas mensagens de frontend: SSLRequest, StartupMessage e Query; testes cobrindo geração de bytes.
- Acrescentadas mensagens de frontend para Parse, Bind, Describe (statement/portal), Execute, Sync e Terminate, com testes unitários validando payloads.
- Implementadas mensagens de backend (Authentication, ParameterStatus, ReadyForQuery, BackendKeyData, RowDescription, DataRow, CommandComplete, Copy, Error/Notice) e o BackendMessageReader que converte PostgresMessage em tipos fortes usando BinaryInput.
- Adicionados testes de backend cobrindo ReadyForQuery, ParameterStatus, Authentication MD5, RowDescription, DataRow e ErrorResponse.

Próximos passos:
- Integrar essa camada com o parser de mensagens do protocolo PostgreSQL (ler mensagem inteira e delegar parsing para um MemoryBinaryInput).
- Adicionar testes adicionais de erro (SocketBinaryInput com onError) e cenários de flush parcial/fragmentado se necessário.
- Integrar com estado de conexão (handshake completo, autenticação, troca de parâmetros) e iniciar camada de pooling.
- Amarrar BackendMessageReader ao fluxo de conexão (autenticação MD5/SASL, ParameterStatus, BackendKeyData, ReadyForQuery).
- Implementar tratamento rico de Error/Notice (mapear para exceções), NotificationResponse e caminhos de Copy/FunctionCall que ainda não têm consumidor.

Progresso 2025-12-05:
- Implementado `NpgsqlConnector` (lib/src/internal/npgsql_connector.dart) gerenciando `Socket`.
- Integrado `PostgresMessageReader` e `BackendMessageReader` no fluxo de conexão.
- Implementado Handshake (StartupMessage, ParameterStatus, BackendKeyData, ReadyForQuery).
- Implementada Autenticação (Cleartext e MD5 usando `pointycastle`).

Progresso 2025-12-05 (Parte 2):
- Implementado tratamento rico de Error/Notice (`PostgresException`) mapeando campos do `ErrorResponse`.
- Criada API pública `NpgsqlConnection` e `NpgsqlCommand`.
- Implementado `NpgsqlDataReader` e suporte a Query Simples (`executeReader`).
- Testes integrados de Handshake, Autenticação e Simple Query (Mock Server).

Progresso 2025-12-05 (Parte 3):
- Implementado suporte básico ao **Extended Query Protocol** (Parse, Bind, Describe, Execute, Sync).
- Adicionados `NpgsqlParameter` e `NpgsqlParameterCollection` para suportar queries parametrizadas.
- Atualizado `NpgsqlDataReader` para coexistir com mensagens de Extended Query (ParseComplete, BindComplete).
- Teste de integração de Query Estendida (Mock Parse/Bind flow).

Progresso 2025-12-05 (Parte 4):
- Implementado `NpgsqlDataSource` com suporte básico a **Pooling de Conexões**.
- Refatorado `NpgsqlConnection` para aceitar conectores existentes (`fromConnector`).
- Teste de integração verificando reuso de conexões (pooling).

Progresso 2025-12-05 (Parte 5):
- **Type Handlers Implementados**: `TypeHandler`, `TypeHandlerRegistry`, `Oid`. Suporte a `Text`, `Integer`, `Bool`.
    - `NpgsqlDataReader` decodifica valores usando handlers quando em formato binário.
    - `NpgsqlConnector` usa handlers para serializar parâmetros binários e requisita resultados em binário.
- **SCRAM-SHA-256 Implementado**: Criado `ScramSha256Authenticator` e integrado ao fluxo de conexão.
- **Cancelamento Implementado**: Adicionado `cancel()` em `NpgsqlConnection` e `cancelRequest()` em `NpgsqlConnector` (abre nova conexão temporária).

Progresso 2025-12-05 (Parte 6):
- **Novos Type Handlers**: Adicionados `Float4` (FloatHandler), `Float8` (DoubleHandler), `Timestamp`, `Date`, `Bytea` (Uint8List).
- **Pooling Melhorado**: `NpgsqlDataSource` agora verifica se a conexão está conectada (`isConnected`) antes de retorná-la do pool.
- **Testes de Tipos Binários**: Criado `test/binary_types_test.dart` simulando resposta binária para Inteiros e validando decodificação.
- **IsConnected**: Exposto getter em `NpgsqlConnector`.

Progresso 2025-12-05 (Parte 7):
- **Arrays Implementados**: Adicionado `ArrayHandler<E>` no `TypeHandler`. Todos os tipos básicos agora têm suporte a Arrays (`int[]`, `text[]`, etc). `resolveByValue` detecta listas.
- **Transações Implementadas**: Criado `NpgsqlTransaction` com suporte a `commit()` e `rollback()`.
- **COPY Proto**: Adicionadas mensagens de Frontend `CopyData`, `CopyDone`, `CopyFail`.

Progresso 2025-12-05 (Parte 9):
- **API de COPY (Binary Import)**: Implementado `beginBinaryImport` em `NpgsqlConnection` e classe `NpgsqlBinaryImporter`.
- **Protocolo COPY**: Suporte a mensagens `CopyData`, `CopyDone`, `CopyFail`, `CopyInResponse` no `NpgsqlConnector`.
- **Sincronização de Protocolo**: Ajustado `awaitCopyComplete` para consumir `ReadyForQuery`, corrigindo bug de sincronia em Simple Query mode.
- **Teste Real COPY**: `test/real_copy_test.dart` criado e passando com sucesso (Insert via COPY + Select verification).

Próximos Passos:
- Implementar `beginBinaryExport` (COPY TO STDOUT).
- Implementar Mock real para SCRAM-SHA-256 para validar autenticação no teste (sem depender de servidor real se possível).
- Refinar robustez de ArrayHandler (multidimensional, nulls) e Text Parsing para Arrays.
- Implementar `Prepare()` para usar Extended Query Protocol explicitamente.

Progresso 2025-12-05 (Parte 10):
- **Refinamento de COPY**:
    - Corrigidos erros de compilação em `NpgsqlBinaryImporter` e `NpgsqlBinaryExporter` (imports, tipos).
    - Adicionado `resolveByDartType<T>` no `TypeHandlerRegistry` para permitir inferência de handler pelo tipo genérico Dart.
    - `NpgsqlBinaryExporter` refatorado para usar `TypeHandler` na leitura (`read<T>`), suportando nativamente `int`, `String`, `bool`, `double`, `DateTime`, `Uint8List`.
    - Leitura e análise do `roteiro_performace.md`, confirmando foco em Extended Protocol e Pipeline como próximos grandes passos.

Próximos Passos:
- Criar teste de integração para `beginBinaryExport` (COPY TO STDOUT).
- Implementar Mock real para SCRAM-SHA-256.
- Refinar ArrayHandler (multidimensional, nulls).
- Implementar `Prepare()` e iniciar suporte a Pipeline Mode.

Progresso 2025-12-05 (Parte 11):
- **COPY Export Finalizado**:
    - Criado teste de integração `test/real_copy_export_test.dart` validando `COPY TO STDOUT` com tipos `int`, `text`, `float8` e `NULL`.
    - Corrigido bug crítico em `NpgsqlBinaryExporter` onde inteiros lidos do stream não eram tratados como signed (causando falha em `ensureBytes` com valores negativos/grandes).
    - Limpeza de código e imports em `NpgsqlBinaryExporter`, `NpgsqlBinaryImporter` e `NpgsqlDataReaderImpl`.
    - `dart analyze lib` limpo (sem erros/warnings).

- [x] **Progresso Part 11**:
    - [x] Implement SCRAM-SHA-256 Mock Server for testing.
    - [x] Fix all lints in test files.
    - [x] Implement `NpgsqlBatch` and `NpgsqlBatchCommand`.
    - [x] Implement `executeBatch` in `NpgsqlConnection` and `NpgsqlConnector` (Pipeline Mode).
    - [x] Verify Pipeline Mode with `test/batch_test.dart`.

## Next Steps
- [ ] **Refine ArrayHandler**:
    - [ ] Support multidimensional arrays (currently only 1D).
    - [ ] Support null values in arrays.
    - [ ] Improve text parsing for complex arrays.
- [ ] **Implement `NpgsqlTransaction`**:
    - [ ] Ensure `Save()` and `Rollback()` work correctly.
- [ ] **Connection Pooling**:
    - [ ] Implement `NpgsqlDataSource` for pooling.
- [ ] **SSL/TLS Support**:
    - [ ] Implement `SslMode` handling.
    - Implementado fluxo de `Parse` + `Describe Statement` + `Sync` no `prepare`.
    - Atualizado `executeReader` para usar `Bind` com `statementName` quando preparado, pulando o `Parse`.
    - Criado teste de integração `test/prepare_test.dart` validando reutilização de statement preparado com diferentes parâmetros.
    - **Nota**: O suporte a `@param` ainda não existe (requer reescrita de SQL), testes usam `$1`.

Progresso 2025-12-05 (Parte 12):
- **Prepare() Implementado**:
    - Adicionado método `prepare()` em `NpgsqlCommand`, `NpgsqlConnection` e `NpgsqlConnector`.
    - Implementado fluxo de `Parse` + `Describe Statement` + `Sync` no `prepare`.
    - Atualizado `executeReader` para usar `Bind` com `statementName` quando preparado, pulando o `Parse`.
    - Criado teste de integração `test/prepare_test.dart` validando reutilização de statement preparado com diferentes parâmetros.
    - **Nota**: O suporte a `@param` ainda não existe (requer reescrita de SQL), testes usam `$1`.

Próximos Passos:
- Implementar Mock real para SCRAM-SHA-256.
- Refinar ArrayHandler.
- Iniciar Pipeline Mode.
- Implementar reescrita de SQL para suportar `@param`.

Progresso 2025-12-05 (Parte 13):
- **SQL Rewriting Implementado**:
    - Criada classe `SqlRewriter` em `lib/src/internal/sql_rewriter.dart` para converter parâmetros nomeados (`@param`) para posicionais (`$1`, `$2`).
    - Integrado `SqlRewriter` em `NpgsqlCommand.prepare()` e `executeReader()`.
    - Atualizado `test/prepare_test.dart` para usar `@id`, validando a reescrita automática e o mapeamento de parâmetros.
    - Suporte a Prepared Statements agora é completo e amigável (estilo Npgsql).

Próximos Passos:
- Implementar Mock real para SCRAM-SHA-256.
- Refinar ArrayHandler.
- Iniciar Pipeline Mode.
