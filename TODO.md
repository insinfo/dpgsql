o foco é criar um driver postgresql de auto desempenho inspirado (portar) o npgsql para dart
C:\MyDartProjects\npgsql\referencias\npgsql-main
foque em ser mais proximo possivel da versão original npgsql ou seja mesmos nomes de classes, arquivos e metodos para facilitar diff
reponda sempre em portugues
continue portando o C:\MyDartProjects\npgsql\referencias\npgsql-main para dart e atualizando o C:\MyDartProjects\npgsql\TODO.md

use o comando rg para buscar no codigo fonte

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
