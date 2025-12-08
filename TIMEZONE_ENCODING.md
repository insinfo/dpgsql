# Suporte a Timezone e Encoding no dpgsql

## Problema de Timezone no Dart (Linux vs Windows)

### Issue: https://github.com/dart-lang/sdk/issues/56312

No Linux, `DateTime(2000)` pode ter um timezone offset diferente de `DateTime.now()` devido a transições históricas de timezone. Isso causa problemas ao decodificar timestamps do PostgreSQL.

**Exemplo do problema:**
```dart
// Windows
DateTime(2000).timeZoneOffset; // -3:00:00 (correto)

// Linux
DateTime(2000).timeZoneOffset; // -2:00:00 (incorreto - transição histórica)
DateTime.now().timeZoneOffset; // -3:00:00 (correto)
```

### Solução Implementada

O `TimestampHandler` e `DateHandler` agora aplicam uma correção automática:

```dart
// Fix timezone transition
final nowDt = DateTime.now();
var baseDt = DateTime(2000);
if (baseDt.timeZoneOffset != nowDt.timeZoneOffset) {
  final difference = baseDt.timeZoneOffset - nowDt.timeZoneOffset;
  baseDt = baseDt.add(difference);
}
```

Isso garante que o timezone base usado para decodificar timestamps seja o timezone atual do sistema, não o histórico.

## Tipos de Timestamp no PostgreSQL

### 1. TIMESTAMP (sem timezone)
- Armazena data/hora sem informação de timezone
- **Não deve** ser convertido para UTC
- Valor armazenado = valor retornado (local time)

```dart
final cmd = conn.createCommand('INSERT INTO test (ts) VALUES (\$1)');
cmd.parameters.addWithValue('ts', DateTime(2024, 7, 19, 11, 10)); // Local time
await cmd.executeNonQuery();

// SELECT retorna o mesmo valor em local time
final reader = await conn.createCommand('SELECT ts FROM test').executeReader();
await reader.read();
final ts = reader.getValue(0) as DateTime; // 2024-07-19 11:10:00 (local)
```

### 2. TIMESTAMPTZ (com timezone)
- Armazena data/hora em UTC internamente
- Converte automaticamente para o timezone da conexão
- Cliente vê o valor em seu timezone local

```dart
final cmd = conn.createCommand('INSERT INTO test (tstz) VALUES (\$1)');
cmd.parameters.addWithValue('tstz', DateTime.now()); // Convertido para UTC
await cmd.executeNonQuery();

// SELECT retorna convertido para local time
final reader = await conn.createCommand('SELECT tstz FROM test').executeReader();
await reader.read();
final tstz = reader.getValue(0) as DateTime; // Local time (convertido do UTC)
```

### 3. DATE
- Armazena apenas data (sem hora)
- Também afetado pelo bug de timezone no Linux
- Fix aplicado automaticamente

```dart
final cmd = conn.createCommand('INSERT INTO test (dt) VALUES (\$1)');
cmd.parameters.addWithValue('dt', DateTime(2024, 7, 19)); // Apenas data
await cmd.executeNonQuery();
```

## Suporte a Encoding

### Encodings Suportados

**UTF8 (padrão):**
```dart
final conn = NpgsqlConnection('Host=localhost;Database=test');
// ou
final conn = NpgsqlConnection('Host=localhost;Database=test;Encoding=UTF8');
```

**Latin1 (ISO-8859-1):**
```dart
final conn = NpgsqlConnection('Host=localhost;Database=sistemas;Encoding=latin1');
```

**ASCII:**
```dart
final conn = NpgsqlConnection('Host=localhost;Database=test;Encoding=ASCII');
```

**WIN1252:**
```dart
// WIN1252 é mapeado para Latin1 (Dart não tem WIN1252 built-in)
final conn = NpgsqlConnection('Host=localhost;Database=test;Encoding=win1252');
```

### Como Usar

```dart
// 1. Especificar na connection string
final conn = NpgsqlConnection('Host=192.168.1.5;Port=5432;Database=sistemas;Encoding=latin1;Username=user;Password=pass');
await conn.open();

// 2. SELECT com dados em Latin1
final results = await conn.createCommand('SELECT nome FROM clientes').executeReader();
while (await results.read()) {
  final nome = results.getValue(0) as String; // Decodificado corretamente como Latin1
  print(nome); // "João Câmara" (caracteres acentuados corretos)
}

// 3. INSERT com dados em Latin1
final cmd = conn.createCommand('INSERT INTO clientes (nome) VALUES (\$1)');
cmd.parameters.addWithValue('nome', 'José da Silva'); // Codificado corretamente
await cmd.executeNonQuery();
```

## Comparação com Outros Drivers

### C# Npgsql
```csharp
// Timestamp sem timezone retorna DateTime local (não UTC)
var dataInicial = reader.GetDateTime(3); 
Console.WriteLine($"dataInicial {dataInicial.Kind == DateTimeKind.Utc}"); // False
```

### Java JDBC
```java
// Timestamp sem timezone retorna LocalDateTime (não ZonedDateTime)
LocalDateTime dataInicial = reader.getObject("dataInicial", LocalDateTime.class);
// Timezone do sistema é usado automaticamente
```

### dpgsql (este driver)
```dart
// Timestamp sem timezone retorna DateTime local (comportamento correto)
final dataInicial = reader.getValue(3) as DateTime;
print('Is UTC: ${dataInicial.isUtc}'); // false
print('Timezone: ${dataInicial.timeZoneOffset}'); // -03:00:00 (timezone local)
```

## Exemplo Completo de Comparação de Datas

```dart
import 'package:dpgsql/dpgsql.dart';

void main() async {
  final conn = NpgsqlConnection('Host=localhost;Database=test');
  await conn.open();
  
  // Criar tabela de teste
  await conn.createCommand('''
    CREATE TABLE IF NOT EXISTS inscricoes (
      id SERIAL PRIMARY KEY,
      data_inicial TIMESTAMP NOT NULL,
      data_final TIMESTAMP NOT NULL
    )
  ''').executeNonQuery();
  
  // Inserir com timezone atual
  final now = DateTime.now();
  final inicio = now.subtract(Duration(minutes: 5));
  final fim = now.add(Duration(hours: 2));
  
  final insertCmd = conn.createCommand('''
    INSERT INTO inscricoes (data_inicial, data_final) 
    VALUES (\$1, \$2)
  ''');
  insertCmd.parameters.addWithValue('inicio', inicio);
  insertCmd.parameters.addWithValue('fim', fim);
  await insertCmd.executeNonQuery();
  
  // Buscar e comparar
  final reader = await conn.createCommand('SELECT * FROM inscricoes').executeReader();
  while (await reader.read()) {
    final dataInicial = reader.getValue(1) as DateTime;
    final dataFinal = reader.getValue(2) as DateTime;
    
    print('Início: $dataInicial (${dataInicial.timeZoneOffset})');
    print('Fim: $dataFinal (${dataFinal.timeZoneOffset})');
    print('Agora: $now (${now.timeZoneOffset})');
    
    // Comparação funciona corretamente!
    if (now.isAfter(dataInicial) && now.isBefore(dataFinal)) {
      print('Inscrições ABERTAS ✓');
    } else {
      print('Inscrições FECHADAS');
    }
  }
  
  await reader.close();
  await conn.close();
}
```

## Referências

- **Dart SDK Issue #56312**: DateTime timezone issue on Linux
- **PostgreSQL Docs**: https://www.postgresql.org/docs/current/datatype-datetime.html
- **Npgsql DateTime**: https://www.npgsql.org/doc/types/datetime.html
- **pg_timezone package**: Inspiração para tratamento correto de timezone
