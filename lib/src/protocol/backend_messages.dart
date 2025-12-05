import 'dart:typed_data';

import '../io/binary_input.dart';
import 'postgres_message.dart';

/// Interface para mensagens de backend (como em Npgsql).
abstract class IBackendMessage {
  BackendMessageCode get code;
}

/// Códigos de mensagens enviadas pelo backend.
enum BackendMessageCode {
  authenticationRequest(0x52), // 'R'
  backendKeyData(0x4B), // 'K'
  bindComplete(0x32), // '2'
  closeComplete(0x33), // '3'
  commandComplete(0x43), // 'C'
  copyData(0x64), // 'd'
  copyDone(0x63), // 'c'
  copyBothResponse(0x57), // 'W'
  copyInResponse(0x47), // 'G'
  copyOutResponse(0x48), // 'H'
  dataRow(0x44), // 'D'
  emptyQueryResponse(0x49), // 'I'
  errorResponse(0x45), // 'E'
  functionCall(0x46), // 'F'
  functionCallResponse(0x56), // 'V'
  noData(0x6E), // 'n'
  noticeResponse(0x4E), // 'N'
  notificationResponse(0x41), // 'A'
  parameterDescription(0x74), // 't'
  parameterStatus(0x53), // 'S'
  parseComplete(0x31), // '1'
  passwordPacket(0x20), // ' '
  portalSuspended(0x73), // 's'
  readyForQuery(0x5A), // 'Z'
  rowDescription(0x54); // 'T'

  const BackendMessageCode(this.typeCode);
  final int typeCode;

  static BackendMessageCode fromTypeCode(int value) {
    for (final c in BackendMessageCode.values) {
      if (c.typeCode == value) return c;
    }
    throw StateError('Código de mensagem de backend desconhecido: $value');
  }
}

enum AuthenticationRequestType {
  ok(0),
  cleartextPassword(3),
  md5Password(5),
  gss(7),
  gssContinue(8),
  sspi(9),
  sasl(10),
  saslContinue(11),
  saslFinal(12);

  const AuthenticationRequestType(this.code);
  final int code;

  static AuthenticationRequestType fromCode(int code) {
    for (final t in AuthenticationRequestType.values) {
      if (t.code == code) return t;
    }
    throw StateError('AuthenticationRequestType desconhecido: $code');
  }
}

enum TransactionStatus {
  idle(0x49), // 'I'
  inTransactionBlock(0x54), // 'T'
  inFailedTransactionBlock(0x45), // 'E'
  pending(0xFF); // estado apenas local, não enviado pelo servidor

  const TransactionStatus(this.indicator);
  final int indicator;

  static TransactionStatus fromIndicator(int indicator) {
    for (final status in TransactionStatus.values) {
      if (status.indicator == indicator) return status;
    }
    throw StateError('TransactionStatus desconhecido: $indicator');
  }
}

/// Formato de dados textual ou binário.
enum DataFormat {
  text(0),
  binary(1);

  const DataFormat(this.code);
  final int code;

  static DataFormat fromCode(int code) {
    switch (code) {
      case 0:
        return DataFormat.text;
      case 1:
        return DataFormat.binary;
      default:
        throw StateError('Formato de dado desconhecido: $code');
    }
  }
}

class BackendMessageReader {
  BackendMessageReader(this._reader);

  final PostgresMessageReader _reader;

  Future<IBackendMessage> readMessage() async {
    final message = await _reader.readMessage();
    return parse(message);
  }

  IBackendMessage parse(PostgresMessage message) {
    final code = BackendMessageCode.fromTypeCode(message.typeCode);
    final input = MemoryBinaryInput(message.payload);

    switch (code) {
      case BackendMessageCode.authenticationRequest:
        return _parseAuthentication(input);
      case BackendMessageCode.backendKeyData:
        return BackendKeyDataMessage(
          processId: input.readInt32(),
          secretKey: input.readInt32(),
        );
      case BackendMessageCode.parameterStatus:
        return ParameterStatusMessage(
          parameter: _readCString(input),
          value: _readCString(input),
        );
      case BackendMessageCode.readyForQuery:
        return ReadyForQueryMessage(
            TransactionStatus.fromIndicator(input.readUint8()));
      case BackendMessageCode.errorResponse:
        return ErrorResponseMessage(_parseErrorOrNotice(input));
      case BackendMessageCode.noticeResponse:
        return NoticeResponseMessage(_parseErrorOrNotice(input));
      case BackendMessageCode.parseComplete:
        return ParseCompleteMessage.instance;
      case BackendMessageCode.bindComplete:
        return BindCompleteMessage.instance;
      case BackendMessageCode.closeComplete:
        return CloseCompletedMessage.instance;
      case BackendMessageCode.noData:
        return NoDataMessage.instance;
      case BackendMessageCode.emptyQueryResponse:
        return EmptyQueryMessage.instance;
      case BackendMessageCode.portalSuspended:
        return PortalSuspendedMessage.instance;
      case BackendMessageCode.commandComplete:
        return CommandCompleteMessage(_readCString(input));
      case BackendMessageCode.rowDescription:
        return _parseRowDescription(input);
      case BackendMessageCode.dataRow:
        return _parseDataRow(input);
      case BackendMessageCode.parameterDescription:
        return _parseParameterDescription(input);
      case BackendMessageCode.notificationResponse:
        return NotificationResponseMessage(
          processId: input.readInt32(),
          channel: _readCString(input),
          payload: _readCString(input),
        );
      case BackendMessageCode.copyInResponse:
      case BackendMessageCode.copyOutResponse:
      case BackendMessageCode.copyBothResponse:
        return _parseCopyResponse(code, input);
      case BackendMessageCode.copyData:
        return CopyDataMessage(
            Uint8List.fromList(input.readBytes(input.remaining)));
      case BackendMessageCode.copyDone:
        return CopyDoneMessage.instance;
      default:
        throw UnsupportedError(
            'Mensagem de backend ainda não suportada: $code');
    }
  }

  AuthenticationRequestMessage _parseAuthentication(MemoryBinaryInput input) {
    final type =
        AuthenticationRequestType.fromCode(input.readInt32());
    switch (type) {
      case AuthenticationRequestType.ok:
        return AuthenticationOkMessage.instance;
      case AuthenticationRequestType.cleartextPassword:
        return AuthenticationCleartextPasswordMessage.instance;
      case AuthenticationRequestType.md5Password:
        return AuthenticationMD5PasswordMessage(
            Uint8List.fromList(input.readBytes(4)));
      case AuthenticationRequestType.gss:
        return AuthenticationGSSMessage.instance;
      case AuthenticationRequestType.gssContinue:
        return AuthenticationGSSContinueMessage(
            Uint8List.fromList(input.readBytes(messageRemaining(input))));
      case AuthenticationRequestType.sspi:
        return AuthenticationSSPIMessage.instance;
      case AuthenticationRequestType.sasl:
        final mechanisms = <String>[];
        while (true) {
          final mech = _readCString(input);
          if (mech.isEmpty) break;
          mechanisms.add(mech);
        }
        if (mechanisms.isEmpty) {
          throw StateError(
              'AuthenticationSASL sem mecanismos enviados pelo servidor');
        }
        return AuthenticationSASLMessage(mechanisms);
      case AuthenticationRequestType.saslContinue:
        return AuthenticationSASLContinueMessage(
            Uint8List.fromList(input.readBytes(messageRemaining(input))));
      case AuthenticationRequestType.saslFinal:
        return AuthenticationSASLFinalMessage(
            Uint8List.fromList(input.readBytes(messageRemaining(input))));
    }
  }

  ErrorOrNoticeMessage _parseErrorOrNotice(MemoryBinaryInput input) {
    final fields = <ErrorFieldTypeCode, String>{};
    while (true) {
      final fieldType = input.readUint8();
      if (fieldType == 0) break;
      final code = ErrorFieldTypeCode.fromType(fieldType);
      fields[code] = _readCString(input);
    }
    return ErrorOrNoticeMessage(fields);
  }

  RowDescriptionMessage _parseRowDescription(MemoryBinaryInput input) {
    final fieldCount = input.readInt16();
    final fields = <FieldDescription>[];
    for (var i = 0; i < fieldCount; i++) {
      fields.add(FieldDescription(
        name: _readCString(input),
        tableOID: input.readInt32(),
        columnAttributeNumber: input.readInt16(),
        oid: input.readInt32(),
        typeSize: input.readInt16(),
        typeModifier: input.readInt32(),
        format: DataFormat.fromCode(input.readInt16()),
      ));
    }
    return RowDescriptionMessage(fields);
  }

  DataRowMessage _parseDataRow(MemoryBinaryInput input) {
    final columnCount = input.readInt16();
    final columns = <Uint8List?>[];
    for (var i = 0; i < columnCount; i++) {
      final len = input.readInt32();
      if (len == -1) {
        columns.add(null);
      } else {
        columns.add(Uint8List.fromList(input.readBytes(len)));
      }
    }
    return DataRowMessage(columns);
  }

  ParameterDescriptionMessage _parseParameterDescription(
      MemoryBinaryInput input) {
    final count = input.readInt16();
    final oids = <int>[];
    for (var i = 0; i < count; i++) {
      oids.add(input.readInt32());
    }
    return ParameterDescriptionMessage(oids);
  }

  CopyResponseMessage _parseCopyResponse(
      BackendMessageCode code, MemoryBinaryInput input) {
    final overallFormat = input.readUint8();
    final columnCount = input.readInt16();
    final columnFormats = <int>[];
    for (var i = 0; i < columnCount; i++) {
      columnFormats.add(input.readInt16());
    }
    final kind = switch (code) {
      BackendMessageCode.copyInResponse => CopyResponseKind.copyIn,
      BackendMessageCode.copyOutResponse => CopyResponseKind.copyOut,
      BackendMessageCode.copyBothResponse => CopyResponseKind.copyBoth,
      _ => throw StateError('Tipo inválido para CopyResponse'),
    };
    return CopyResponseMessage(
      kind: kind,
      overallFormat: overallFormat,
      columnFormatCodes: columnFormats,
    );
  }
}

int messageRemaining(MemoryBinaryInput input) =>
    input.remaining; // bytes restantes no payload.

String _readCString(MemoryBinaryInput input) {
  final bytes = <int>[];
  while (true) {
    final b = input.readUint8();
    if (b == 0) break;
    bytes.add(b);
  }
  return String.fromCharCodes(bytes);
}

sealed class AuthenticationRequestMessage implements IBackendMessage {
  const AuthenticationRequestMessage(this.authRequestType);

  @override
  BackendMessageCode get code => BackendMessageCode.authenticationRequest;

  final AuthenticationRequestType authRequestType;
}

final class AuthenticationOkMessage extends AuthenticationRequestMessage {
  const AuthenticationOkMessage() : super(AuthenticationRequestType.ok);
  static const instance = AuthenticationOkMessage();
}

final class AuthenticationCleartextPasswordMessage
    extends AuthenticationRequestMessage {
  const AuthenticationCleartextPasswordMessage()
      : super(AuthenticationRequestType.cleartextPassword);
  static const instance = AuthenticationCleartextPasswordMessage();
}

final class AuthenticationMD5PasswordMessage
    extends AuthenticationRequestMessage {
  AuthenticationMD5PasswordMessage(this.salt)
      : super(AuthenticationRequestType.md5Password);

  final Uint8List salt;
}

final class AuthenticationGSSMessage extends AuthenticationRequestMessage {
  const AuthenticationGSSMessage() : super(AuthenticationRequestType.gss);
  static const instance = AuthenticationGSSMessage();
}

final class AuthenticationGSSContinueMessage
    extends AuthenticationRequestMessage {
  AuthenticationGSSContinueMessage(this.authenticationData)
      : super(AuthenticationRequestType.gssContinue);

  final Uint8List authenticationData;
}

final class AuthenticationSSPIMessage extends AuthenticationRequestMessage {
  const AuthenticationSSPIMessage() : super(AuthenticationRequestType.sspi);
  static const instance = AuthenticationSSPIMessage();
}

final class AuthenticationSASLMessage extends AuthenticationRequestMessage {
  AuthenticationSASLMessage(this.mechanisms)
      : super(AuthenticationRequestType.sasl);

  final List<String> mechanisms;
}

final class AuthenticationSASLContinueMessage
    extends AuthenticationRequestMessage {
  AuthenticationSASLContinueMessage(this.payload)
      : super(AuthenticationRequestType.saslContinue);

  final Uint8List payload;
}

final class AuthenticationSASLFinalMessage
    extends AuthenticationRequestMessage {
  AuthenticationSASLFinalMessage(this.payload)
      : super(AuthenticationRequestType.saslFinal);

  final Uint8List payload;
}

final class BackendKeyDataMessage implements IBackendMessage {
  BackendKeyDataMessage({required this.processId, required this.secretKey});

  @override
  BackendMessageCode get code => BackendMessageCode.backendKeyData;

  final int processId;
  final int secretKey;
}

final class ParameterStatusMessage implements IBackendMessage {
  ParameterStatusMessage({required this.parameter, required this.value});

  @override
  BackendMessageCode get code => BackendMessageCode.parameterStatus;

  final String parameter;
  final String value;
}

final class ReadyForQueryMessage implements IBackendMessage {
  ReadyForQueryMessage(this.transactionStatusIndicator);

  @override
  BackendMessageCode get code => BackendMessageCode.readyForQuery;

  final TransactionStatus transactionStatusIndicator;
}

final class ParseCompleteMessage implements IBackendMessage {
  const ParseCompleteMessage();

  @override
  BackendMessageCode get code => BackendMessageCode.parseComplete;

  static const instance = ParseCompleteMessage();
}

final class BindCompleteMessage implements IBackendMessage {
  const BindCompleteMessage();

  @override
  BackendMessageCode get code => BackendMessageCode.bindComplete;

  static const instance = BindCompleteMessage();
}

final class CloseCompletedMessage implements IBackendMessage {
  const CloseCompletedMessage();

  @override
  BackendMessageCode get code => BackendMessageCode.closeComplete;

  static const instance = CloseCompletedMessage();
}

final class NoDataMessage implements IBackendMessage {
  const NoDataMessage();

  @override
  BackendMessageCode get code => BackendMessageCode.noData;

  static const instance = NoDataMessage();
}

final class EmptyQueryMessage implements IBackendMessage {
  const EmptyQueryMessage();

  @override
  BackendMessageCode get code => BackendMessageCode.emptyQueryResponse;

  static const instance = EmptyQueryMessage();
}

final class PortalSuspendedMessage implements IBackendMessage {
  const PortalSuspendedMessage();

  @override
  BackendMessageCode get code => BackendMessageCode.portalSuspended;

  static const instance = PortalSuspendedMessage();
}

final class CommandCompleteMessage implements IBackendMessage {
  CommandCompleteMessage(this.commandTag);

  @override
  BackendMessageCode get code => BackendMessageCode.commandComplete;

  final String commandTag;
}

final class RowDescriptionMessage implements IBackendMessage {
  RowDescriptionMessage(this.fields);

  @override
  BackendMessageCode get code => BackendMessageCode.rowDescription;

  final List<FieldDescription> fields;
}

final class FieldDescription {
  FieldDescription({
    required this.name,
    required this.tableOID,
    required this.columnAttributeNumber,
    required this.oid,
    required this.typeSize,
    required this.typeModifier,
    required this.format,
  });

  String name;
  int tableOID;
  int columnAttributeNumber;
  int oid;
  int typeSize;
  int typeModifier;
  DataFormat format;
}

final class DataRowMessage implements IBackendMessage {
  DataRowMessage(this.columns);

  @override
  BackendMessageCode get code => BackendMessageCode.dataRow;

  final List<Uint8List?> columns;
}

final class ParameterDescriptionMessage implements IBackendMessage {
  ParameterDescriptionMessage(this.parameterOids);

  @override
  BackendMessageCode get code => BackendMessageCode.parameterDescription;

  final List<int> parameterOids;
}

final class NotificationResponseMessage implements IBackendMessage {
  NotificationResponseMessage({
    required this.processId,
    required this.channel,
    required this.payload,
  });

  @override
  BackendMessageCode get code => BackendMessageCode.notificationResponse;

  final int processId;
  final String channel;
  final String payload;
}

enum CopyResponseKind { copyIn, copyOut, copyBoth }

final class CopyResponseMessage implements IBackendMessage {
  CopyResponseMessage({
    required this.kind,
    required this.overallFormat,
    required this.columnFormatCodes,
  });

  @override
  BackendMessageCode get code => switch (kind) {
        CopyResponseKind.copyIn => BackendMessageCode.copyInResponse,
        CopyResponseKind.copyOut => BackendMessageCode.copyOutResponse,
        CopyResponseKind.copyBoth => BackendMessageCode.copyBothResponse,
      };

  final CopyResponseKind kind;
  final int overallFormat;
  final List<int> columnFormatCodes;
}

final class CopyDataMessage implements IBackendMessage {
  CopyDataMessage(this.data);

  @override
  BackendMessageCode get code => BackendMessageCode.copyData;

  final Uint8List data;
}

final class CopyDoneMessage implements IBackendMessage {
  const CopyDoneMessage();

  @override
  BackendMessageCode get code => BackendMessageCode.copyDone;

  static const instance = CopyDoneMessage();
}

final class ErrorResponseMessage implements IBackendMessage {
  ErrorResponseMessage(this.error);

  @override
  BackendMessageCode get code => BackendMessageCode.errorResponse;

  final ErrorOrNoticeMessage error;
}

final class NoticeResponseMessage implements IBackendMessage {
  NoticeResponseMessage(this.notice);

  @override
  BackendMessageCode get code => BackendMessageCode.noticeResponse;

  final ErrorOrNoticeMessage notice;
}

/// Campos que podem aparecer em ErrorResponse/NoticeResponse.
enum ErrorFieldTypeCode {
  severity(0x53), // 'S'
  invariantSeverity(0x56), // 'V'
  code(0x43), // 'C'
  message(0x4D), // 'M'
  detail(0x44), // 'D'
  hint(0x48), // 'H'
  position(0x50), // 'P'
  internalPosition(0x70), // 'p'
  internalQuery(0x71), // 'q'
  where(0x57), // 'W'
  schemaName(0x73), // 's'
  tableName(0x74), // 't'
  columnName(0x63), // 'c'
  dataTypeName(0x64), // 'd'
  constraintName(0x6E), // 'n'
  file(0x46), // 'F'
  line(0x4C), // 'L'
  routine(0x52); // 'R'

  const ErrorFieldTypeCode(this.type);
  final int type;

  static ErrorFieldTypeCode fromType(int type) {
    for (final c in ErrorFieldTypeCode.values) {
      if (c.type == type) return c;
    }
    return ErrorFieldTypeCode.message;
  }
}

final class ErrorOrNoticeMessage {
  ErrorOrNoticeMessage(this.fields);

  final Map<ErrorFieldTypeCode, String> fields;

  String? get severity => fields[ErrorFieldTypeCode.severity];
  String? get invariantSeverity => fields[ErrorFieldTypeCode.invariantSeverity];
  String? get sqlState => fields[ErrorFieldTypeCode.code];
  String? get messageText => fields[ErrorFieldTypeCode.message];
  String? get detail => fields[ErrorFieldTypeCode.detail];
  String? get hint => fields[ErrorFieldTypeCode.hint];
  int? get position => _parseIntField(ErrorFieldTypeCode.position);
  int? get internalPosition =>
      _parseIntField(ErrorFieldTypeCode.internalPosition);
  String? get internalQuery => fields[ErrorFieldTypeCode.internalQuery];
  String? get where => fields[ErrorFieldTypeCode.where];
  String? get schemaName => fields[ErrorFieldTypeCode.schemaName];
  String? get tableName => fields[ErrorFieldTypeCode.tableName];
  String? get columnName => fields[ErrorFieldTypeCode.columnName];
  String? get dataTypeName => fields[ErrorFieldTypeCode.dataTypeName];
  String? get constraintName => fields[ErrorFieldTypeCode.constraintName];
  String? get file => fields[ErrorFieldTypeCode.file];
  String? get line => fields[ErrorFieldTypeCode.line];
  String? get routine => fields[ErrorFieldTypeCode.routine];

  int? _parseIntField(ErrorFieldTypeCode field) {
    final raw = fields[field];
    if (raw == null) return null;
    return int.tryParse(raw);
  }
}
