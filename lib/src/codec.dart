import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cbor/simple.dart' as cbor;
import 'package:cryptography/cryptography.dart';

/// Serialize → zlib (threshold) → AES-256-GCM.
///
/// Wire layout of one record payload (after length prefix in `.dat`):
/// `[flags:u8][nonce:12][mac:16][ciphertext…]` when encrypted,
/// or `[flags:u8][payload…]` when not.
class StoreCodec {
  StoreCodec({
    SecretKey? secretKey,
    this.compressThreshold = 512,
    this.encrypted = true,
  }) : _secretKey = secretKey;

  static const int flagCompressed = 0x01;
  static const int flagEncrypted = 0x02;
  static const int nonceLen = 12;
  static const int macLen = 16;

  final SecretKey? _secretKey;
  final int compressThreshold;
  final bool encrypted;

  /// The key this codec encrypts/decrypts with, if any. Exposed so other
  /// engines on the same store (e.g. [VorzBlobStore]) can share it instead
  /// of each needing their own key plumbed through separately.
  SecretKey? get secretKey => _secretKey;

  final _aes = AesGcm.with256bits();
  final _zlib = ZLibCodec(level: 6);

  /// Encode a JSON-compatible map to durable bytes.
  Future<Uint8List> encode(
    Map<String, dynamic> map, {
    required List<int> aad,
  }) async {
    final cborBytes = Uint8List.fromList(cbor.cbor.encode(_cborSafe(map)));
    return encodeRaw(cborBytes, aad: aad);
  }

  /// Decode durable bytes back to a map.
  Future<Map<String, dynamic>> decode(
    Uint8List bytes, {
    required List<int> aad,
  }) async {
    final payload = await decodeRaw(bytes, aad: aad);
    final decoded = cbor.cbor.decode(payload);
    if (decoded is! Map) {
      throw const FormatException('store record is not a map');
    }
    return _asStringKeyedMap(decoded);
  }

  /// Compress (if large enough) + encrypt (if enabled) arbitrary bytes.
  /// Used for record payloads (via [encode]) and for the collection index,
  /// so index metadata gets the same at-rest protection as records instead
  /// of sitting on disk as plaintext JSON.
  Future<Uint8List> encodeRaw(
    Uint8List payload, {
    required List<int> aad,
  }) async {
    var p = payload;
    var flags = 0;

    if (p.length >= compressThreshold) {
      p = Uint8List.fromList(_zlib.encode(p));
      flags |= flagCompressed;
    }

    if (encrypted) {
      final key = _secretKey;
      if (key == null) {
        throw StateError('encrypted store requires a DEK');
      }
      flags |= flagEncrypted;
      final box = await _aes.encrypt(
        p,
        secretKey: key,
        aad: aad,
      );
      final out = Uint8List(1 + nonceLen + macLen + box.cipherText.length);
      out[0] = flags;
      out.setRange(1, 1 + nonceLen, box.nonce);
      out.setRange(1 + nonceLen, 1 + nonceLen + macLen, box.mac.bytes);
      out.setRange(1 + nonceLen + macLen, out.length, box.cipherText);
      return out;
    }

    final out = Uint8List(1 + p.length);
    out[0] = flags;
    out.setRange(1, out.length, p);
    return out;
  }

  /// Inverse of [encodeRaw]: returns the raw (decompressed, decrypted)
  /// payload bytes without assuming they're CBOR.
  Future<Uint8List> decodeRaw(
    Uint8List bytes, {
    required List<int> aad,
  }) async {
    if (bytes.isEmpty) {
      throw const FormatException('empty store record');
    }
    final flags = bytes[0];
    var payload = bytes.sublist(1);

    if ((flags & flagEncrypted) != 0) {
      final key = _secretKey;
      if (key == null) {
        throw StateError('encrypted record but no DEK');
      }
      if (payload.length < nonceLen + macLen) {
        throw const FormatException('truncated ciphertext');
      }
      final nonce = payload.sublist(0, nonceLen);
      final mac = Mac(payload.sublist(nonceLen, nonceLen + macLen));
      final cipherText = payload.sublist(nonceLen + macLen);
      final clear = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: key,
        aad: aad,
      );
      payload = Uint8List.fromList(clear);
    }

    if ((flags & flagCompressed) != 0) {
      payload = Uint8List.fromList(_zlib.decode(payload));
    }

    return Uint8List.fromList(payload);
  }

  /// Compare storage size vs JSON+gzip for the same map (tests / docs).
  static int jsonGzipSize(Map<String, dynamic> map) {
    final json = utf8.encode(jsonEncode(map));
    return GZipCodec().encode(json).length;
  }

  static int cborZlibSize(Map<String, dynamic> map, {int threshold = 512}) {
    final raw = cbor.cbor.encode(_cborSafe(map));
    if (raw.length < threshold) return raw.length;
    return ZLibCodec().encode(raw).length;
  }

  static dynamic _cborSafe(dynamic v) {
    if (v == null || v is bool || v is num || v is String) return v;
    if (v is Uint8List) return v;
    if (v is List) return v.map(_cborSafe).toList();
    if (v is Map) {
      return {
        for (final e in v.entries) e.key.toString(): _cborSafe(e.value),
      };
    }
    return v.toString();
  }

  static Map<String, dynamic> _asStringKeyedMap(Map raw) {
    return {
      for (final e in raw.entries) e.key.toString(): _jsonify(e.value),
    };
  }

  static dynamic _jsonify(dynamic v) {
    if (v == null || v is bool || v is num || v is String) return v;
    if (v is Uint8List) return base64Encode(v);
    if (v is List) return v.map(_jsonify).toList();
    if (v is Map) return _asStringKeyedMap(v);
    return v;
  }
}
