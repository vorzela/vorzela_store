import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'collection.dart';
import 'store.dart';

/// Where a blob currently stands relative to your backend.
///
/// This store does not talk to your backend itself — you set/read
/// [syncState] as your sync logic uploads/downloads, and the store uses it
/// only to decide what's safe to evict (see [VorzBlobStore.maxTotalBytes]).
enum BlobSyncState {
  /// Only exists locally; not yet backed up anywhere. Never auto-evicted.
  local,

  /// Upload/download in flight.
  syncing,

  /// Exists locally and on the backend — safe to evict and re-fetch later.
  synced,

  /// Metadata only, no local bytes (e.g. after eviction or before first
  /// download). [VorzBlobStore.getBytes] / [getStream] return nothing.
  remoteOnly,
}

class BlobMeta {
  BlobMeta({
    required this.key,
    required this.size,
    this.mimeType,
    this.remoteUrl,
    this.syncState = BlobSyncState.local,
    DateTime? createdAt,
    DateTime? lastAccessed,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        lastAccessed = lastAccessed ?? DateTime.now().toUtc();

  final String key;
  final int size;
  final String? mimeType;
  final String? remoteUrl;
  final BlobSyncState syncState;
  final DateTime createdAt;
  final DateTime lastAccessed;

  BlobMeta copyWith({
    BlobSyncState? syncState,
    String? remoteUrl,
    DateTime? lastAccessed,
  }) {
    return BlobMeta(
      key: key,
      size: size,
      mimeType: mimeType,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      syncState: syncState ?? this.syncState,
      createdAt: createdAt,
      lastAccessed: lastAccessed ?? this.lastAccessed,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'size': size,
        'mimeType': mimeType,
        'remoteUrl': remoteUrl,
        'syncState': syncState.name,
        'createdAt': createdAt.toIso8601String(),
        'lastAccessed': lastAccessed.toIso8601String(),
      };

  static BlobMeta fromJson(Map<String, dynamic> j) => BlobMeta(
        key: j['key'] as String,
        size: j['size'] as int,
        mimeType: j['mimeType'] as String?,
        remoteUrl: j['remoteUrl'] as String?,
        syncState: BlobSyncState.values.firstWhere(
          (s) => s.name == j['syncState'],
          orElse: () => BlobSyncState.local,
        ),
        createdAt: DateTime.parse(j['createdAt'] as String),
        lastAccessed: DateTime.parse(j['lastAccessed'] as String),
      );
}

/// Streaming, chunk-encrypted blob store for files/media — images, PDFs,
/// downloaded attachments — that are too large or too write-heavy for the
/// document engine's CBOR+JSON-index path.
///
/// Each blob lives at `<store>/blobs/<encoded-key>.blob` as a sequence of
/// independently-encrypted, length-prefixed frames:
/// `[frameLen:u32][flag:u8][salt:4][mac:16][ciphertext…]`. Writing and
/// reading both work chunk-by-chunk (default 64 KiB), so a multi-hundred-MB
/// file never needs to sit fully in memory just to be encrypted or decrypted.
///
/// Metadata (size, mime type, remote URL, sync state) is stored as a normal
/// document in a `__blobs_meta__` collection on the same [VorzStore], so it
/// gets the same durability/index handling as everything else, and
/// `meta.size` lets [getBytes] detect a truncated/corrupted blob file.
///
/// This does not implement a formal streaming-AEAD "last chunk" marker —
/// each chunk is independently authenticated, but a *streamed* read
/// ([getStream]) can't on its own detect a file truncated exactly on a
/// chunk boundary. [getBytes] catches that by checking the total against
/// the recorded (encrypted, tamper-evident) `size` metadata; if you consume
/// [getStream] directly for very large files, compare bytes read against
/// [BlobMeta.size] yourself.
class VorzBlobStore {
  VorzBlobStore._(this._dir, this._metaCol, this._secretKey, this.maxTotalBytes);

  final Directory _dir;
  final VorzCollection<Map<String, dynamic>> _metaCol;
  final SecretKey? _secretKey;

  /// Soft cap on total blob bytes on disk. When exceeded, the
  /// least-recently-accessed blobs with [BlobSyncState.synced] or a
  /// [BlobMeta.remoteUrl] (i.e. re-fetchable) are evicted first.
  /// `null` disables eviction.
  final int? maxTotalBytes;

  static const int chunkSize = 64 * 1024;
  static const int _macLen = 16;
  static const int _saltLen = 4;

  final _aes = AesGcm.with256bits();

  /// Opens (or creates) the blob store alongside [store]'s own data.
  ///
  /// Defaults to encrypting with `store.dek` — the same key already
  /// protecting the store's documents — so blobs are encrypted
  /// automatically for an encrypted store. Pass a different [secretKey] to
  /// use a separate key, or `inheritStoreKey: false` (with no [secretKey])
  /// to deliberately store blobs unencrypted.
  static Future<VorzBlobStore> open(
    VorzStore store, {
    SecretKey? secretKey,
    bool inheritStoreKey = true,
    int? maxTotalBytes,
  }) async {
    final dir = Directory(p.join(store.directory.path, 'blobs'));
    await dir.create(recursive: true);
    final metaCol = await store.maps(
      '__blobs_meta__',
      indexes: ['syncState'],
    );
    final effectiveKey =
        secretKey ?? (inheritStoreKey ? store.dek : null);
    return VorzBlobStore._(dir, metaCol, effectiveKey, maxTotalBytes);
  }

  File _fileFor(String key) => File(p.join(_dir.path, '${_safeName(key)}.blob'));

  String _safeName(String key) =>
      base64Url.encode(utf8.encode(key)).replaceAll('=', '');

  Uint8List _nonceFor(List<int> salt, int chunkIndex) {
    final b = ByteData(12);
    for (var i = 0; i < _saltLen; i++) {
      b.setUint8(i, salt[i]);
    }
    b.setUint64(4, chunkIndex, Endian.big);
    return b.buffer.asUint8List();
  }

  /// Write [data] under [key], encrypting and flushing chunk-by-chunk.
  /// Overwrites any existing blob under the same key.
  Future<BlobMeta> putStream(
    String key,
    Stream<List<int>> data, {
    String? mimeType,
    String? remoteUrl,
    BlobSyncState syncState = BlobSyncState.local,
  }) async {
    final tmpFile = File('${_fileFor(key).path}.tmp');
    final raf = await tmpFile.open(mode: FileMode.write);

    var totalSize = 0;
    var chunkIndex = 0;
    var pending = Uint8List(0);

    Future<void> flushChunk(Uint8List chunk) async {
      await _writeChunk(raf, key, chunk, chunkIndex);
      totalSize += chunk.length;
      chunkIndex++;
    }

    try {
      await for (final part in data) {
        final merged = Uint8List(pending.length + part.length)
          ..setRange(0, pending.length, pending)
          ..setRange(pending.length, pending.length + part.length, part);
        var offset = 0;
        while (merged.length - offset >= chunkSize) {
          await flushChunk(
            Uint8List.sublistView(merged, offset, offset + chunkSize),
          );
          offset += chunkSize;
        }
        // Copy (not a view) so the — possibly much larger — `merged`
        // buffer this chunk came from can be released.
        pending = Uint8List.fromList(merged.sublist(offset));
      }
      // Always write a final frame, even for an empty blob (0 chunks would
      // leave the file empty and indistinguishable from "not found").
      await flushChunk(pending);
      await raf.flush();
    } catch (_) {
      await raf.close();
      if (await tmpFile.exists()) await tmpFile.delete();
      rethrow;
    }
    await raf.close();

    final target = _fileFor(key);
    if (await target.exists()) await target.delete();
    await tmpFile.rename(target.path);

    final meta = BlobMeta(
      key: key,
      size: totalSize,
      mimeType: mimeType,
      remoteUrl: remoteUrl,
      syncState: syncState,
    );
    await _metaCol.put(key, meta.toJson());
    await _evictIfNeeded();
    return meta;
  }

  Future<BlobMeta> putBytes(
    String key,
    Uint8List bytes, {
    String? mimeType,
    String? remoteUrl,
    BlobSyncState syncState = BlobSyncState.local,
  }) {
    return putStream(
      key,
      Stream.value(bytes),
      mimeType: mimeType,
      remoteUrl: remoteUrl,
      syncState: syncState,
    );
  }

  Future<void> _writeChunk(
    RandomAccessFile raf,
    String key,
    Uint8List chunk,
    int chunkIndex,
  ) async {
    final salt = Uint8List(_saltLen);
    final rnd = Random.secure();
    for (var i = 0; i < salt.length; i++) {
      salt[i] = rnd.nextInt(256);
    }

    Uint8List frame;
    final key0 = _secretKey;
    if (key0 != null) {
      final aad = utf8.encode('$key|$chunkIndex');
      final box = await _aes.encrypt(
        chunk,
        secretKey: key0,
        nonce: _nonceFor(salt, chunkIndex),
        aad: aad,
      );
      frame = Uint8List(1 + _saltLen + _macLen + box.cipherText.length);
      frame[0] = 1; // encrypted
      frame.setRange(1, 1 + _saltLen, salt);
      frame.setRange(1 + _saltLen, 1 + _saltLen + _macLen, box.mac.bytes);
      frame.setRange(1 + _saltLen + _macLen, frame.length, box.cipherText);
    } else {
      frame = Uint8List(1 + chunk.length);
      frame[0] = 0; // plain
      frame.setRange(1, frame.length, chunk);
    }

    final header = ByteData(4)..setUint32(0, frame.length, Endian.big);
    await raf.writeFrom(header.buffer.asUint8List());
    await raf.writeFrom(frame);
  }

  /// Stream a blob's decrypted bytes, chunk-by-chunk. Empty stream if the
  /// key doesn't exist or has no local bytes ([BlobSyncState.remoteOnly]).
  Stream<List<int>> getStream(String key) async* {
    final file = _fileFor(key);
    if (!await file.exists()) return;

    final raf = await file.open(mode: FileMode.read);
    var chunkIndex = 0;
    try {
      while (true) {
        final lenBytes = await raf.read(4);
        if (lenBytes.length < 4) break;
        final frameLen =
            ByteData.sublistView(Uint8List.fromList(lenBytes)).getUint32(0, Endian.big);
        final frame = Uint8List.fromList(await raf.read(frameLen));
        if (frame.length < frameLen) {
          throw const FormatException('truncated blob chunk');
        }
        final flag = frame[0];
        if (flag == 1) {
          final key0 = _secretKey;
          if (key0 == null) {
            throw StateError('blob "$key" is encrypted but no key was provided');
          }
          final salt = frame.sublist(1, 1 + _saltLen);
          final mac = Mac(frame.sublist(1 + _saltLen, 1 + _saltLen + _macLen));
          final cipherText = frame.sublist(1 + _saltLen + _macLen);
          final aad = utf8.encode('$key|$chunkIndex');
          final clear = await _aes.decrypt(
            SecretBox(cipherText, nonce: _nonceFor(salt, chunkIndex), mac: mac),
            secretKey: key0,
            aad: aad,
          );
          yield clear;
        } else {
          yield frame.sublist(1);
        }
        chunkIndex++;
      }
    } finally {
      await raf.close();
    }
    // Await (don't fire-and-forget): otherwise a later store.close() /
    // tearDown can close the meta collection's RAF while touch is mid-put.
    try {
      await _touchAccess(key);
    } catch (_) {
      // Best-effort LRU bookkeeping — ignore if the store was closed.
    }
  }

  /// Read a whole blob into memory. Prefer [getStream] for large files.
  /// Throws [FormatException] if the assembled bytes don't match the
  /// recorded size (truncated/corrupted file).
  Future<Uint8List?> getBytes(String key) async {
    final meta = await this.meta(key);
    if (meta == null) return null;
    if (meta.syncState == BlobSyncState.remoteOnly) {
      return null; // no local bytes to read — not an error
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in getStream(key)) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != meta.size) {
      throw FormatException(
        'blob "$key" truncated or corrupted: expected ${meta.size} bytes, got ${bytes.length}',
      );
    }
    return bytes;
  }

  /// Record that [key] exists on your backend without fetching its bytes
  /// yet — e.g. after syncing a file listing. [getBytes]/[getStream] return
  /// nothing until you actually [putBytes]/[putStream] the content (at
  /// which point set `syncState: BlobSyncState.synced`).
  Future<BlobMeta> registerRemote(
    String key, {
    required int size,
    required String remoteUrl,
    String? mimeType,
  }) async {
    final meta = BlobMeta(
      key: key,
      size: size,
      mimeType: mimeType,
      remoteUrl: remoteUrl,
      syncState: BlobSyncState.remoteOnly,
    );
    await _metaCol.put(key, meta.toJson());
    return meta;
  }

  Future<BlobMeta?> meta(String key) async {
    final m = await _metaCol.get(key);
    return m == null ? null : BlobMeta.fromJson(m);
  }

  Future<void> _touchAccess(String key) async {
    final m = await _metaCol.get(key);
    if (m == null) return;
    m['lastAccessed'] = DateTime.now().toUtc().toIso8601String();
    await _metaCol.put(key, m);
  }

  /// Update sync/remote state after your own upload/download logic runs.
  Future<void> markSynced(String key, {String? remoteUrl}) async {
    final m = await meta(key);
    if (m == null) return;
    await _metaCol.put(
      key,
      m.copyWith(syncState: BlobSyncState.synced, remoteUrl: remoteUrl).toJson(),
    );
  }

  Future<void> delete(String key) async {
    final f = _fileFor(key);
    if (await f.exists()) await f.delete();
    await _metaCol.delete(key);
  }

  Future<int> totalBytes() async {
    var sum = 0;
    for (final k in await _metaCol.keys()) {
      final m = await _metaCol.get(k);
      sum += (m?['size'] as int?) ?? 0;
    }
    return sum;
  }

  Future<void> _evictIfNeeded() async {
    final cap = maxTotalBytes;
    if (cap == null) return;

    var total = await totalBytes();
    if (total <= cap) return;

    final candidates = <MapEntry<String, DateTime>>[];
    for (final k in await _metaCol.keys()) {
      final m = await _metaCol.get(k);
      if (m == null) continue;
      final state = m['syncState'] as String?;
      final hasRemote = m['remoteUrl'] != null;
      // Never auto-evict data that only exists locally and isn't backed up
      // anywhere — that would silently destroy the user's only copy.
      if (state == BlobSyncState.local.name && !hasRemote) continue;
      candidates.add(
        MapEntry(k, DateTime.parse(m['lastAccessed'] as String)),
      );
    }
    candidates.sort((a, b) => a.value.compareTo(b.value)); // oldest first

    for (final e in candidates) {
      if (total <= cap) break;
      final m = await _metaCol.get(e.key);
      final size = (m?['size'] as int?) ?? 0;
      await delete(e.key);
      total -= size;
    }
  }
}
