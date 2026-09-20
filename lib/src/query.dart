import 'package:vorzela_json/vorzela_json.dart';

import 'collection.dart';

/// Equality / sort / limit query over a [VorzCollection].
class VorzQuery<T> {
  VorzQuery(this._collection);

  final VorzCollection<T> _collection;

  String? _field;
  String? _eqValue;
  String? _sortField;
  bool _sortDesc = false;
  int? _limit;

  /// Equality filter on an indexed field.
  ///
  /// [value] must not be `null` — a null would previously look like "no
  /// filter" and silently fall back to a full scan. Pass a concrete value
  /// (e.g. empty string) if that is what you mean to match.
  VorzQuery<T> whereEq(String field, Object? value) {
    if (value == null) {
      throw ArgumentError.value(
        value,
        'value',
        'whereEq does not accept null; that would silently full-scan',
      );
    }
    _field = field;
    _eqValue = value.toString();
    return this;
  }

  VorzQuery<T> sortBy(String field, {bool desc = false}) {
    _sortField = field;
    _sortDesc = desc;
    return this;
  }

  VorzQuery<T> limit(int n) {
    _limit = n;
    return this;
  }

  Future<List<T>> find() async {
    final List<String> keys;
    if (_field != null && _eqValue != null) {
      keys = await _collection.engine.keysWhereEq(
        _collection.name,
        _field!,
        _eqValue!,
      );
    } else {
      keys = await _collection.keys();
    }

    final items = <T>[];
    for (final k in keys) {
      final v = await _collection.get(k);
      if (v != null) items.add(v);
    }

    if (_sortField != null) {
      final field = _sortField!;
      items.sort((a, b) {
        final cmp = _compare(_fieldValue(a, field), _fieldValue(b, field));
        return _sortDesc ? -cmp : cmp;
      });
    }

    if (_limit != null && items.length > _limit!) {
      return items.sublist(0, _limit!);
    }
    return items;
  }

  dynamic _fieldValue(T value, String field) {
    if (value is JsonModel) return value.toJson()[field];
    if (value is Map) return value[field];
    return null;
  }

  int _compare(dynamic a, dynamic b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    if (a is Comparable && b is Comparable) {
      return Comparable.compare(a, b);
    }
    return a.toString().compareTo(b.toString());
  }
}
