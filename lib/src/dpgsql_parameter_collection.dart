import 'dart:collection';
import 'dpgsql_parameter.dart';

/// Represents a collection of parameters associated with a DpgsqlCommand.
/// Porting DpgsqlParameterCollection.cs
class DpgsqlParameterCollection extends ListBase<DpgsqlParameter> {
  final List<DpgsqlParameter> _internalList = [];

  @override
  int get length => _internalList.length;

  @override
  set length(int newLength) => _internalList.length = newLength;

  @override
  DpgsqlParameter operator [](int index) => _internalList[index];

  @override
  void operator []=(int index, DpgsqlParameter value) =>
      _internalList[index] = value;

  @override
  void add(DpgsqlParameter element) => _internalList.add(element);

  void addWithValue(String name, dynamic value) {
    add(DpgsqlParameter(name, value));
  }
}
