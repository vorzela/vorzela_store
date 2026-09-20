import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vorzela_json/vorzela_json.dart';

import 'codec.dart';
import 'collection.dart';
import 'engine.dart';
import 'file_engine.dart';
import 'memory_engine.dart';
import 'secure_key.dart';

/// Durable encrypted document store.
class VorzStore {
  VorzStore._({
    required this.name,
    required this.directory,
    required StoreEngine engine,
    required StoreCodec codec,
    required DekStore dekStore,
    required this.encrypted,
    required this.schemaVersion,
  })  : _engine = engine,
        _codec = codec,
        _dekStore = dekStore;

  final String name;
  final Directory directory;
  final bool encrypted;
  final int schemaVersion;

  final StoreEngine _engine;
  final StoreCodec _codec;
  final DekStore _dekStore;
  final Map<String, VorzCollection<dynamic>> _collections = {};
  bool _closed = false;

  /// The store's data-encryption key, if [encrypted]. `null` for an
  /// unencrypted store. Other engines built on top of this store's
  /// directory (e.g. [VorzBlobStore]) use this by default so blobs get the
  /// same at-rest protection as documents instead of silently landing on
  /// disk in plaintext.
  SecretKey? get dek => _codec.secretKey;

  /// Open a store under Application Support (survives reboot).
  ///
  /// Pass [directory] to override (tests). Pass [dekStore] / [engine] for
  /// tests (e.g. [MemoryDekStore], [MemoryEngine]).
  static Future<VorzStore> open({
    required String name,
    Directory? directory,
    bool encrypted = true,
    bool compactOnOpen = false,
    int schemaVersion = 1,
    DekStore? dekStore,
    StoreEngine? engine,
    SecretKey? secretKey,
  }) async {
    final dir = directory ??
        Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'vorzela_store',
            name,
          ),
        );
    await dir.create(recursive: true);

    final meta = File(p.join(dir.path, 'meta.json'));
    if (!await meta.exists()) {
      await meta.writeAsString(
        jsonEncode({
          'name': name,
          'schemaVersion': schemaVersion,
          'encrypted': encrypted,
        }),
      );
    }

    final keys = dekStore ?? SecureDekStore();
    SecretKey? dek = secretKey;
    if (encrypted && dek == null) {
      dek = await loadOrCreateDek(storeName: name, dekStore: keys);
    }

    final codec = StoreCodec(secretKey: dek, encrypted: encrypted);
    final storeEngine = engine ?? FileEngine(dir);
    if (storeEngine is FileEngine) {
      // Index metadata (keys, offsets, indexed field values) gets the same
      // at-rest protection as record payloads instead of sitting on disk
      // as plaintext JSON.
      storeEngine.attachIndexCodec(codec);
    }
    if (compactOnOpen && storeEngine is FileEngine) {
      // Collections opened lazily; compact after first use via store.compact().
    }

    return VorzStore._(
      name: name,
      directory: dir,
      engine: storeEngine,
      codec: codec,
      dekStore: keys,
      encrypted: encrypted,
      schemaVersion: schemaVersion,
    );
  }

  /// Open an in-memory store (tests).
  static Future<VorzStore> openMemory({
    String name = 'mem',
    bool encrypted = true,
    SecretKey? secretKey,
    DekStore? dekStore,
  }) async {
    final keys = dekStore ?? MemoryDekStore();
    final dek = encrypted
        ? (secretKey ??
            await loadOrCreateDek(storeName: name, dekStore: keys))
        : null;
    return VorzStore._(
      name: name,
      directory: Directory.systemTemp,
      engine: MemoryEngine(),
      codec: StoreCodec(secretKey: dek, encrypted: encrypted),
      dekStore: keys,
      encrypted: encrypted,
      schemaVersion: 1,
    );
  }

  /// Typed collection. [fromJson] rebuilds models; [toJson] optional if [T]
  /// is [JsonModel] or `Map<String, dynamic>`.
  Future<VorzCollection<T>> collection<T>(
    String name, {
    required FromJson<T> fromJson,
    ToJson<T>? toJson,
    List<String> indexes = const [],
  }) async {
    _ensureOpen();
    final existing = _collections[name];
    if (existing != null) {
      return existing as VorzCollection<T>;
    }

    await _engine.openCollection(name, indexFields: indexes);
    final col = VorzCollection<T>(
      name: name,
      engine: _engine,
      codec: _codec,
      storeName: this.name,
      schemaVersion: schemaVersion,
      fromJson: fromJson,
      toJson: toJson ?? _defaultToJson<T>,
      indexes: indexes,
    );
    _collections[name] = col;
    return col;
  }

  /// Convenience for raw maps.
  Future<VorzCollection<Map<String, dynamic>>> maps(
    String name, {
    List<String> indexes = const [],
  }) {
    return collection<Map<String, dynamic>>(
      name,
      fromJson: (m) => m,
      toJson: (m) => m,
      indexes: indexes,
    );
  }

  /// Convenience for [JsonModel] subclasses.
  Future<VorzCollection<T>> models<T extends JsonModel>(
    String name, {
    required FromJson<T> fromJson,
    List<String> indexes = const [],
  }) {
    return collection<T>(
      name,
      fromJson: fromJson,
      toJson: (m) => m.toJson(),
      indexes: indexes,
    );
  }

  Future<void> compact([String? collection]) async {
    _ensureOpen();
    await _engine.compact(collection);
  }

  /// Deletes the DEK — ciphertext remains but becomes unreadable.
  Future<void> wipeKeys() async {
    await _dekStore.delete(name);
  }

  Future<void> close() async {
    if (_closed) return;
    for (final c in _collections.values) {
      await c.closeWatchers();
    }
    _collections.clear();
    await _engine.close();
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('VorzStore "$name" is closed');
  }

  static Map<String, dynamic> _defaultToJson<T>(T value) {
    if (value is JsonModel) return value.toJson();
    if (value is Map<String, dynamic>) return value;
    throw ArgumentError(
      'Provide toJson for type $T (or use JsonModel / Map)',
    );
  }
}
