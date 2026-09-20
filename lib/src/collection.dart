import 'dart:async';
import 'dart:typed_data';

import 'package:vorzela_json/vorzela_json.dart';

import 'codec.dart';
import 'engine.dart';
import 'query.dart';

typedef FromJson<T> = T Function(Map<String, dynamic> json);
typedef ToJson<T> = Map<String, dynamic> Function(T value);

/// Typed document collection.
class VorzCollection<T> {
  VorzCollection({
    required this.name,
    required StoreEngine engine,
    required StoreCodec codec,
    required this.storeName,
    required this.schemaVersion,
    required FromJson<T> fromJson,
    required ToJson<T> toJson,
    List<String> indexes = const [],
  })  : _engine = engine,
        _codec = codec,
        _fromJson = fromJson,
        _toJson = toJson,
        indexFields = List.unmodifiable(indexes);

  final String name;
  final String storeName;
  final int schemaVersion;
  final List<String> indexFields;

  final StoreEngine _engine;
  final StoreCodec _codec;
  final FromJson<T> _fromJson;
  final ToJson<T> _toJson;

  final Map<String, StreamController<T?>> _watchers = {};

  StoreEngine get engine => _engine;
  FromJson<T> get fromJson => _fromJson;

  List<int> _aad(String key) =>
      '$storeName|$name|$key|$schemaVersion'.codeUnits;

  Map<String, dynamic> _asMap(T value) {
    if (value is JsonModel) return value.toJson();
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    return _toJson(value);
  }

  Map<String, String>? _indexMap(Map<String, dynamic> map) {
    if (indexFields.isEmpty) return null;
    final out = <String, String>{};
    for (final f in indexFields) {
      final v = map[f];
      if (v != null) out[f] = v.toString();
    }
    return out.isEmpty ? null : out;
  }

  Future<void> put(String key, T value) async {
    final map = _asMap(value);
    final oldIdx = await _engine.indexValues(name, key);
    final record = await _codec.encode(map, aad: _aad(key));
    // One engine commit: ciphertext + equality indexes together.
    await _engine.put(
      name,
      key,
      record,
      oldIndex: oldIdx,
      newIndex: _indexMap(map),
    );
    _emit(key, value);
  }

  Future<T?> get(String key) async {
    final bytes = await _engine.get(name, key);
    if (bytes == null) return null;
    final map = await _codec.decode(bytes, aad: _aad(key));
    return _fromJson(map);
  }

  Future<void> delete(String key) async {
    final oldIdx = await _engine.indexValues(name, key);
    await _engine.delete(name, key, oldIndex: oldIdx);
    _emit(key, null);
  }

  Future<void> putAll(Map<String, T> entries) async {
    if (entries.isEmpty) return;
    final records = <String, Uint8List>{};
    final olds = <String, Map<String, String>?>{};
    final news = <String, Map<String, String>?>{};

    for (final e in entries.entries) {
      final map = _asMap(e.value);
      olds[e.key] = await _engine.indexValues(name, e.key);
      news[e.key] = _indexMap(map);
      records[e.key] = await _codec.encode(map, aad: _aad(e.key));
    }

    await _engine.putAll(
      name,
      records,
      oldIndexes: olds,
      newIndexes: news,
    );

    for (final e in entries.entries) {
      _emit(e.key, e.value);
    }
  }

  void _emit(String key, T? value) {
    final c = _watchers[key];
    if (c != null && !c.isClosed) c.add(value);
  }

  Stream<T?> watch(String key) {
    final existing = _watchers[key];
    if (existing != null) return existing.stream;

    late final StreamController<T?> controller;
    controller = StreamController<T?>.broadcast(
      onCancel: () async {
        if (!controller.hasListener) {
          final c = _watchers.remove(key);
          await c?.close();
        }
      },
    );
    _watchers[key] = controller;
    scheduleMicrotask(() async {
      final v = await get(key);
      if (!controller.isClosed) controller.add(v);
    });
    return controller.stream;
  }

  VorzQuery<T> query() => VorzQuery<T>(this);

  Future<List<String>> keys() => _engine.keys(name);

  Future<void> closeWatchers() async {
    for (final c in _watchers.values) {
      await c.close();
    }
    _watchers.clear();
  }
}
