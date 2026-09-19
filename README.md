# vorzela_store

Durable, encrypted NoSQL document store for Flutter. No Hive. No SQL.

**License:** MIT · **Repo:** https://github.com/vorzela/vorzela_store

---

## Why

App data that must:

- survive phone reboot
- stay encrypted at rest (AES-256-GCM)
- stay small on disk (CBOR + zlib, slot reuse, auto-compact)
- stay simple (`open` → `put` / `get` / `query`)

Models use [`vorzela_json`](https://github.com/vorzela/vorzela_json).

---

## Quick start

```dart
import 'package:vorzela_store/vorzela_store.dart';
import 'package:vorzela_json/vorzela_json.dart';

class User extends JsonModel {
  User([super.data]);
  User.fromJson(super.json) : super.fromJson();

  String get name => $str('name');
  set name(String v) => $set('name', v);

  String get role => $str('role');
  set role(String v) => $set('role', v);
}

final store = await VorzStore.open(name: 'app'); // encrypted by default

final users = await store.models<User>(
  'users',
  fromJson: User.fromJson,
  indexes: ['role'],
);

await users.put('u1', User({'name': 'Ada', 'role': 'admin'}));
final u = await users.get('u1'); // still there after reboot

final admins = await users.query().whereEq('role', 'admin').find();

await store.compact(); // optional reclaim
await store.close();
```

Logout / wipe crypto keys (files remain but are unreadable):

```dart
await store.wipeKeys();
```

---

## How it stores data

```text
Map / JsonModel  →  CBOR  →  zlib (if ≥ ~512B)  →  AES-256-GCM  →  .dat
```

Files live under **Application Support** (not cache/tmp):

```text
<support>/vorzela_store/<name>/
  meta.json
  <collection>.dat   # length-prefixed encrypted records
  <collection>.idx   # key → offset/length + equality indexes
```

Durability: flush `.dat`, then atomically replace `.idx`. Index only points at flushed bytes.

Growth control:

1. **Slot reuse** when an update fits the previous slot
2. **Tombstones** for deletes / oversized updates
3. **Auto-compact** when dead space ≥ 25% or ≥ 4 MiB (also `store.compact()`)

Do not store media blobs — keep URLs and put binaries in object storage.

---

## Security

| Piece | Where |
|-------|--------|
| DEK (256-bit) | Keychain / Keystore via `flutter_secure_storage` |
| Values | AES-256-GCM, unique nonce per record |
| AAD | `dbName\|collection\|key\|schemaVersion` |

Protects disk / backup extraction. A rooted live process can still read memory.

---

## Dependencies

| Package | Why |
|---------|-----|
| `path_provider` | Durable app directory |
| `flutter_secure_storage` | DEK survives reboot |
| `cryptography` | AES-GCM |
| `cbor` | Compact binary (not JSON text on disk) |
| `vorzela_json` | Models |

No Hive, Isar, ObjectBox, or SQLite.

---

## Tests

```bash
cd vorzela_store && flutter test
```
