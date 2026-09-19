import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vorzela_json/vorzela_json.dart';
import 'package:vorzela_store/vorzela_store.dart';

class User extends JsonModel {
  User([super.data]);
  User.fromJson(super.json) : super.fromJson();

  String get name => $str('name');
  set name(String v) => $set('name', v);

  String get role => $str('role');
  set role(String v) => $set('role', v);

  int get updatedAt => $int('updatedAt');
  set updatedAt(int v) => $set('updatedAt', v);
}

void main() {
  group('StoreCodec', () {
    test('round-trip encrypt + compress', () async {
      final key = await AesGcm.with256bits().newSecretKey();
      final codec = StoreCodec(secretKey: key, compressThreshold: 8);
      final map = {
        'name': 'Ada',
        'bio': 'x' * 200,
        'tags': ['a', 'b'],
      };
      final aad = 'db|users|u1|1'.codeUnits;
      final bytes = await codec.encode(map, aad: aad);
      final out = await codec.decode(bytes, aad: aad);
      expect(out['name'], 'Ada');
      expect(out['bio'], map['bio']);
      expect(out['tags'], ['a', 'b']);
    });

    test('wrong AAD / key fails', () async {
      final key = await AesGcm.with256bits().newSecretKey();
      final codec = StoreCodec(secretKey: key);
      final bytes = await codec.encode(
        {'a': 1},
        aad: 'right'.codeUnits,
      );
      expect(
        () => codec.decode(bytes, aad: 'wrong'.codeUnits),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      final other = StoreCodec(
        secretKey: await AesGcm.with256bits().newSecretKey(),
      );
      expect(
        () => other.decode(bytes, aad: 'right'.codeUnits),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('CBOR+zlib smaller than JSON+gzip on repetitive docs', () {
      final map = {
        for (var i = 0; i < 40; i++) 'field_$i': 'value_repeated_$i' * 3,
      };
      final jsonGz = StoreCodec.jsonGzipSize(map);
      final cborZl = StoreCodec.cborZlibSize(map, threshold: 64);
      expect(cborZl, lessThan(jsonGz));
    });
  });

  group('VorzStore memory', () {
    test('put get delete query watch', () async {
      final store = await VorzStore.openMemory(name: 't1');
      final users = await store.models<User>(
        'users',
        fromJson: User.fromJson,
        indexes: ['role', 'updatedAt'],
      );

      await users.put(
        'u1',
        User({'name': 'Ada', 'role': 'admin', 'updatedAt': 2}),
      );
      await users.put(
        'u2',
        User({'name': 'Bob', 'role': 'member', 'updatedAt': 1}),
      );
      await users.put(
        'u3',
        User({'name': 'Cid', 'role': 'admin', 'updatedAt': 3}),
      );

      final ada = await users.get('u1');
      expect(ada?.name, 'Ada');

      final admins = await users
          .query()
          .whereEq('role', 'admin')
          .sortBy('updatedAt', desc: true)
          .limit(10)
          .find();
      expect(admins.map((u) => u.name).toList(), ['Cid', 'Ada']);

      final events = <String?>[];
      final sub = users.watch('u1').listen((u) => events.add(u?.name));
      await Future<void>.delayed(Duration.zero);
      await users.put(
        'u1',
        User({'name': 'Ada2', 'role': 'admin', 'updatedAt': 4}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(events, contains('Ada'));
      expect(events, contains('Ada2'));

      await users.delete('u2');
      expect(await users.get('u2'), isNull);

      await store.close();
    });
  });

  group('VorzStore file durable', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('vorzela_store_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('survives reopen (reboot equivalent)', () async {
      final dek = MemoryDekStore();
      final keyBytes = List<int>.generate(32, (i) => i + 1);

      final store1 = await VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
        secretKey: SecretKey(keyBytes),
      );
      await dek.write('app', Uint8List.fromList(keyBytes));
      final users1 = await store1.models<User>(
        'users',
        fromJson: User.fromJson,
        indexes: ['role'],
      );
      await users1.put('u1', User({'name': 'Ada', 'role': 'admin'}));
      await store1.close();

      final store2 = await VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
        secretKey: SecretKey(keyBytes),
      );
      final users2 = await store2.models<User>(
        'users',
        fromJson: User.fromJson,
        indexes: ['role'],
      );
      expect((await users2.get('u1'))?.name, 'Ada');
      await store2.close();
    });

    test('slot reuse + compact reclaim dead space', () async {
      final engine = FileEngine(
        dir,
        autoCompactRatio: 1.0, // disable auto; exercise manual compact
        autoCompactMinDeadBytes: 1 << 30,
      );
      final dek = MemoryDekStore();
      final key = await AesGcm.with256bits().newSecretKey();
      final keyBytes = await key.extractBytes();
      await dek.write('app', Uint8List.fromList(keyBytes));

      final store = await VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
        engine: engine,
        secretKey: key,
      );
      final col = await store.maps('docs');

      await col.put('a', {'v': 'x' * 200});
      final size1 = await engine.dataFileSize('docs');
      await col.put('a', {'v': 'y' * 200});
      await col.put('b', {'v': 'z' * 200});
      await col.delete('b');

      final dead = await engine.deadBytes('docs');
      expect(dead, greaterThan(0));

      await store.compact('docs');
      expect(await engine.deadBytes('docs'), 0);
      expect(await engine.dataFileSize('docs'), lessThan(size1 * 3));
      expect((await col.get('a'))?['v'], 'y' * 200);

      await store.close();
    });

    test('partial trailing bytes ignored on reopen', () async {
      final dek = MemoryDekStore();
      final keyBytes = List<int>.generate(32, (i) => 7);
      final key = SecretKey(keyBytes);
      await dek.write('app', Uint8List.fromList(keyBytes));

      final store1 = await VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
        secretKey: key,
      );
      final col1 = await store1.maps('docs');
      await col1.put('ok', {'n': 1});
      await store1.close();

      final dat = File('${dir.path}/docs.dat');
      await dat.writeAsBytes(
        [...await dat.readAsBytes(), 1, 2, 3, 4, 5],
        flush: true,
      );

      final store2 = await VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
        secretKey: key,
      );
      final col2 = await store2.maps('docs');
      expect((await col2.get('ok'))?['n'], 1);
      await store2.close();
    });

    test('wipeKeys makes data unreadable', () async {
      final dek = MemoryDekStore();
      final keyBytes = List<int>.generate(32, (i) => 3);
      await dek.write('app', Uint8List.fromList(keyBytes));

      final store1 = await VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
        secretKey: SecretKey(keyBytes),
      );
      await (await store1.maps('docs')).put('k', {'a': 1});
      await store1.wipeKeys();
      await store1.close();

      final store2 = await VorzStore.open(
        name: 'app',
        directory: dir,
        dekStore: dek,
      );
      final col = await store2.maps('docs');
      expect(() => col.get('k'), throwsA(anything));
      await store2.close();
    });
  });
}
