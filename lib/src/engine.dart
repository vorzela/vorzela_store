import 'dart:typed_data';

/// Low-level document engine: opaque encrypted records keyed by string.
abstract class StoreEngine {
  Future<void> openCollection(String name, {List<String> indexFields = const []});

  Future<void> put(String collection, String key, Uint8List record);

  Future<Uint8List?> get(String collection, String key);

  Future<void> delete(String collection, String key);

  Future<void> putAll(String collection, Map<String, Uint8List> records);

  /// All live keys in [collection].
  Future<List<String>> keys(String collection);

  /// Keys matching equality index [field] == [value] (stringified).
  Future<List<String>> keysWhereEq(
    String collection,
    String field,
    String value,
  );

  /// Update equality indexes for [key] from old/new field maps (string values).
  ///
  /// [commit] controls whether the on-disk index is flushed immediately.
  /// Batch callers (e.g. [VorzCollection.putAll]) pass `commit: false` for
  /// every entry but the last so an N-document batch does one index flush
  /// instead of N.
  Future<void> setIndexValues(
    String collection,
    String key, {
    Map<String, String>? oldValues,
    Map<String, String>? newValues,
    bool commit = true,
  });

  Future<Map<String, String>?> indexValues(String collection, String key);

  Future<void> compact([String? collection]);

  Future<void> close();

  /// Approximate on-disk bytes for [collection] (data file).
  Future<int> dataFileSize(String collection);

  Future<int> deadBytes(String collection);
}
