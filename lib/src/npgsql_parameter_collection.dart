import 'dart:collection';
import 'npgsql_parameter.dart';

/// Represents a collection of parameters associated with a NpgsqlCommand.
/// Porting NpgsqlParameterCollection.cs
class NpgsqlParameterCollection extends ListBase<NpgsqlParameter> {
  final List<NpgsqlParameter> _internalList = [];

  @override
  int get length => _internalList.length;

  @override
  set length(int newLength) => _internalList.length = newLength;

  @override
  NpgsqlParameter operator [](int index) => _internalList[index];

  @override
  void operator []=(int index, NpgsqlParameter value) =>
      _internalList[index] = value;

  @override
  void add(NpgsqlParameter element) => _internalList.add(element);

  void addWithValue(String name, dynamic value) {
    add(NpgsqlParameter(name, value));
  }
}
