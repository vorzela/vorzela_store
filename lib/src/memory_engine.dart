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

  void _applyIndex(
    String collection,
    String key, {
    Map<String, String>? oldValues,
    Map<String, String>? newValues,
  }) {
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
    } else if (oldValues != null) {
      _docIndexes[collection]?.remove(key);
    }
  }

  @override
  Future<void> put(
    String collection,
    String key,
    Uint8List record, {
    Map<String, String>? oldIndex,
    Map<String, String>? newIndex,
  }) async {
    _data[collection]![key] = Uint8List.fromList(record);
    if (oldIndex != null || newIndex != null) {
      _applyIndex(
        collection,
        key,
        oldValues: oldIndex,
        newValues: newIndex,
      );
    }
  }

  @override
  Future<Uint8List?> get(String collection, String key) async {
    final v = _data[collection]?[key];
    return v == null ? null : Uint8List.fromList(v);
  }

  @override
  Future<void> delete(
    String collection,
    String key, {
    Map<String, String>? oldIndex,
  }) async {
    _data[collection]?.remove(key);
    _applyIndex(collection, key, oldValues: oldIndex, newValues: null);
  }

  @override
  Future<void> putAll(
    String collection,
    Map<String, Uint8List> records, {
    Map<String, Map<String, String>?>? oldIndexes,
    Map<String, Map<String, String>?>? newIndexes,
  }) async {
    for (final e in records.entries) {
      await put(
        collection,
        e.key,
        e.value,
        oldIndex: oldIndexes?[e.key],
        newIndex: newIndexes?[e.key],
      );
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
    _applyIndex(
      collection,
      key,
      oldValues: oldValues,
      newValues: newValues,
    );
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
