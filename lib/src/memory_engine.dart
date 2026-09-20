import 'dart:typed_data';

import 'engine.dart';

/// In-memory [StoreEngine] for unit tests.
class MemoryEngine implements StoreEngine {
  final Map<String, Map<String, Uint8List>> _data = {};
  final Map<String, List<String>> _indexFields = {};
  final Map<String, Map<String, Map<String, String>>> _docIndexes = {};
  final Map<String, Map<String, Map<String, Set<String>>>> _eq = {};

  @override
  Future<void> openCollection(
    String name, {
    List<String> indexFields = const [],
  }) async {
    _data.putIfAbsent(name, () => {});
    _indexFields[name] = List.of(indexFields);
    _docIndexes.putIfAbsent(name, () => {});
    _eq.putIfAbsent(name, () => {
          for (final f in indexFields) f: <String, Set<String>>{},
        });
  }

  @override
  Future<void> put(String collection, String key, Uint8List record) async {
    _data[collection]![key] = Uint8List.fromList(record);
  }

  @override
  Future<Uint8List?> get(String collection, String key) async {
    final v = _data[collection]?[key];
    return v == null ? null : Uint8List.fromList(v);
  }

  @override
  Future<void> delete(String collection, String key) async {
    _data[collection]?.remove(key);
  }

  @override
  Future<void> putAll(String collection, Map<String, Uint8List> records) async {
    for (final e in records.entries) {
      await put(collection, e.key, e.value);
    }
  }

  @override
  Future<List<String>> keys(String collection) async =>
      _data[collection]?.keys.toList() ?? [];

  @override
  Future<List<String>> keysWhereEq(
    String collection,
    String field,
    String value,
  ) async {
    final set = _eq[collection]?[field]?[value];
    return set?.toList() ?? [];
  }

  @override
  Future<void> setIndexValues(
    String collection,
    String key, {
    Map<String, String>? oldValues,
    Map<String, String>? newValues,
    bool commit = true,
  }) async {
    final eq = _eq[collection];
    if (eq == null) return;

    if (oldValues != null) {
      for (final e in oldValues.entries) {
        eq[e.key]?[e.value]?.remove(key);
      }
    }
    if (newValues != null) {
      _docIndexes[collection]![key] = Map.of(newValues);
      for (final e in newValues.entries) {
        eq.putIfAbsent(e.key, () => {});
        eq[e.key]!.putIfAbsent(e.value, () => {}).add(key);
      }
    } else {
      _docIndexes[collection]?.remove(key);
    }
  }

  @override
  Future<Map<String, String>?> indexValues(
    String collection,
    String key,
  ) async =>
      _docIndexes[collection]?[key] == null
          ? null
          : Map.of(_docIndexes[collection]![key]!);

  @override
  Future<void> compact([String? collection]) async {}

  @override
  Future<void> close() async {}

  @override
  Future<int> dataFileSize(String collection) async {
    final m = _data[collection];
    if (m == null) return 0;
    var n = 0;
    for (final v in m.values) {
      n += v.length;
    }
    return n;
  }

  @override
  Future<int> deadBytes(String collection) async => 0;
}
