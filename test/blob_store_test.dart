import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vorzela_store/vorzela_store.dart';

void main() {
  group('VorzBlobStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('vorzela_blob_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<VorzStore> openStore({int? maxTotalBytes}) async {
      final dek = MemoryDekStore();
      final keyBytes = List<int>.generate(32, (i) => i + 2);
      await dek.write('app', Uint8List.fromList(keyBytes));
      return VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
        secretKey: SecretKey(keyBytes),
      );
    }

    test('round-trip bytes smaller than one chunk', () async {
      final store = await openStore();
      final blobs = await VorzBlobStore.open(store);

      final bytes = Uint8List.fromList(List.generate(100, (i) => i % 256));
      await blobs.putBytes('a', bytes, mimeType: 'application/octet-stream');

      final out = await blobs.getBytes('a');
      expect(out, bytes);

      final meta = await blobs.meta('a');
      expect(meta?.size, 100);
      expect(meta?.mimeType, 'application/octet-stream');
      await store.close();
    });

    test('round-trip bytes spanning multiple chunks', () async {
      final store = await openStore();
      final blobs = await VorzBlobStore.open(store);

      // A bit over 2.5 chunks, with a non-round tail, exercises the
      // merge/flush boundary logic in putStream.
      final size = (VorzBlobStore.chunkSize * 2.5).round() + 37;
      final bytes = Uint8List.fromList(
        List.generate(size, (i) => (i * 7) % 256),
      );
      await blobs.putBytes('big', bytes);

      final out = await blobs.getBytes('big');
      expect(out, bytes);
      await store.close();
    });

    test('putStream from a chunked Stream reassembles correctly', () async {
      final store = await openStore();
      final blobs = await VorzBlobStore.open(store);

      final full = Uint8List.fromList(
        List.generate(VorzBlobStore.chunkSize + 500, (i) => i % 256),
      );
      // Feed it in small, irregular pieces to simulate an HTTP byte stream.
      final parts = <List<int>>[];
      var i = 0;
      while (i < full.length) {
        final n = 1000 + (i % 300);
        final end = (i + n).clamp(0, full.length);
        parts.add(full.sublist(i, end));
        i = end;
      }
      await blobs.putStream('streamed', Stream.fromIterable(parts));

      final out = await blobs.getBytes('streamed');
      expect(out, full);
      await store.close();
    });

    test('survives reopen (offline cache persists)', () async {
      final dek = MemoryDekStore();
      final keyBytes = List<int>.generate(32, (i) => i + 5);
      await dek.write('app', Uint8List.fromList(keyBytes));

      final store1 = await VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
        secretKey: SecretKey(keyBytes),
      );
      final blobs1 = await VorzBlobStore.open(store1);
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      await blobs1.putBytes('f', bytes, remoteUrl: 'https://example.com/f');
      await store1.close();

      final store2 = await VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
        secretKey: SecretKey(keyBytes),
      );
      final blobs2 = await VorzBlobStore.open(store2);
      expect(await blobs2.getBytes('f'), bytes);
      expect((await blobs2.meta('f'))?.remoteUrl, 'https://example.com/f');
      await store2.close();
    });

    test('evicts oldest synced/re-fetchable blobs over the cap', () async {
      final store = await openStore();
      final withCap = await VorzBlobStore.open(store, maxTotalBytes: 250);

      final chunk = Uint8List.fromList(List.filled(100, 1));
      await withCap.putBytes(
        'old',
        chunk,
        remoteUrl: 'https://example.com/old',
        syncState: BlobSyncState.synced,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await withCap.putBytes(
        'mid',
        chunk,
        remoteUrl: 'https://example.com/mid',
        syncState: BlobSyncState.synced,
      );
      // Pushes total over the 250-byte cap; 'old' (least recently
      // accessed, re-fetchable) should be evicted.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await withCap.putBytes(
        'new',
        chunk,
        remoteUrl: 'https://example.com/new',
        syncState: BlobSyncState.synced,
      );

      expect(await withCap.getBytes('old'), isNull);
      expect(await withCap.getBytes('mid'), isNotNull);
      expect(await withCap.getBytes('new'), isNotNull);
      await store.close();
    });

    test('never evicts local-only unsynced data', () async {
      final store = await openStore();
      final blobs = await VorzBlobStore.open(store, maxTotalBytes: 50);

      final chunk = Uint8List.fromList(List.filled(100, 2));
      // No remoteUrl, default syncState.local — must never be silently
      // deleted even though it's the only thing over the (tiny) cap.
      await blobs.putBytes('draft', chunk);

      expect(await blobs.getBytes('draft'), chunk);
      await store.close();
    });

    test('registerRemote: known-but-not-downloaded has metadata, no bytes', () async {
      final store = await openStore();
      final blobs = await VorzBlobStore.open(store);

      await blobs.registerRemote(
        'x',
        size: 12345,
        remoteUrl: 'https://example.com/x',
        mimeType: 'image/png',
      );

      final meta = await blobs.meta('x');
      expect(meta?.size, 12345);
      expect(meta?.syncState, BlobSyncState.remoteOnly);
      expect(await blobs.getBytes('x'), isNull); // not downloaded yet

      // Now "download" it.
      final bytes = Uint8List.fromList(List.filled(12345, 7));
      await blobs.putBytes(
        'x',
        bytes,
        remoteUrl: 'https://example.com/x',
        mimeType: 'image/png',
        syncState: BlobSyncState.synced,
      );
      expect(await blobs.getBytes('x'), bytes);
      await store.close();
    });
  });
}
