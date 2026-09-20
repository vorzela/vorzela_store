import 'dart:typed_data';

/// Low-level document engine: opaque encrypted records keyed by string.
abstract class StoreEngine {
  Future<void> openCollection(String name, {List<String> indexFields = const []});

  /// Write [record] and optionally update equality indexes in **one** index
  /// commit (avoids a crash window where data is durable but indexes are not).
  Future<void> put(
    String collection,
    String key,
    Uint8List record, {
    Map<String, String>? oldIndex,
    Map<String, String>? newIndex,
  });

  Future<Uint8List?> get(String collection, String key);

  /// Remove [key] and clear its equality indexes in one index commit.
  Future<void> delete(
    String collection,
    String key, {
    Map<String, String>? oldIndex,
  });

  /// Batch write + index updates, single index flush at the end.
  Future<void> putAll(
    String collection,
    Map<String, Uint8List> records, {
    Map<String, Map<String, String>?>? oldIndexes,
    Map<String, Map<String, String>?>? newIndexes,
  });

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
  /// Prefer passing indexes into [put] / [putAll] / [delete] so data + index
  /// share one disk commit. This remains for rare out-of-band updates.
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

  /// Approximate on-disk bytes for [collection] (logical data size).
  Future<int> dataFileSize(String collection);

  Future<int> deadBytes(String collection);
}
