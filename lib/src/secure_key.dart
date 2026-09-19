import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the data-encryption key (DEK). Implementations must survive reboot.
abstract class DekStore {
  Future<Uint8List?> read(String storeName);
  Future<void> write(String storeName, Uint8List bytes);
  Future<void> delete(String storeName);
}

/// In-memory DEK store for tests.
class MemoryDekStore implements DekStore {
  final Map<String, Uint8List> _keys = {};

  @override
  Future<Uint8List?> read(String storeName) async => _keys[storeName];

  @override
  Future<void> write(String storeName, Uint8List bytes) async {
    _keys[storeName] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String storeName) async {
    _keys.remove(storeName);
  }
}

/// DEK in platform Keychain / Keystore via [FlutterSecureStorage].
class SecureDekStore implements DekStore {
  SecureDekStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  String _key(String storeName) => 'vorzela_store_dek_$storeName';

  @override
  Future<Uint8List?> read(String storeName) async {
    final b64 = await _storage.read(key: _key(storeName));
    if (b64 == null || b64.isEmpty) return null;
    return Uint8List.fromList(base64Decode(b64));
  }

  @override
  Future<void> write(String storeName, Uint8List bytes) async {
    await _storage.write(key: _key(storeName), value: base64Encode(bytes));
  }

  @override
  Future<void> delete(String storeName) async {
    await _storage.delete(key: _key(storeName));
  }
}

/// Loads or creates a 256-bit AES DEK for [storeName].
Future<SecretKey> loadOrCreateDek({
  required String storeName,
  required DekStore dekStore,
}) async {
  final existing = await dekStore.read(storeName);
  if (existing != null && existing.length == 32) {
    return SecretKey(existing);
  }
  final algo = AesGcm.with256bits();
  final key = await algo.newSecretKey();
  final bytes = Uint8List.fromList(await key.extractBytes());
  await dekStore.write(storeName, bytes);
  return SecretKey(bytes);
}
