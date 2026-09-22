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

Durability: flush `.dat`, then atomically replace `.idx` via write-temp +
rename (never delete-the-live-index-first). Data + equality indexes share
**one** index commit per `put`/`delete`/`putAll`. Logical append offset
comes from the committed index so a crash mid-append cannot shift later
writes into orphan junk. Compact swaps `.dat` with rename-over / backup
dance — it does not delete the live data file before the new one is in place.

Growth control:

1. **Slot reuse** when an update fits the previous slot
2. **Tombstones** for deletes / oversized updates
3. **Auto-compact** when dead space ≥ 25% or ≥ 4 MiB (also `store.compact()`)
4. **Batched index commits** — `putAll()` does one index-file rewrite for
   the whole batch, not one per document
5. All engine operations on a collection are serialized (per-collection
   async lock), so concurrent `put`/`delete`/`compact` calls can't race and
   corrupt the `.dat`/`.idx` files

### Honesty vs SQLite

This is a young, purpose-built engine — not a drop-in for SQLite/SQLCipher.
We close the usual first-order footguns (interleaved awaits, plaintext
indexes, delete-before-rename, put-then-index double commits, FD leaks on
re-open, orphan trailing bytes after a crash). We have **not** had decades
of power-loss / filesystem / multi-process stress testing. Prefer it for
encrypted offline app documents and caches; keep using SQLite when you need
that battle history, complex queries, or multi-process writers.

For files and media (images, PDFs, downloaded attachments) too large or
write-heavy for the document engine, use `VorzBlobStore` instead of putting
them through a regular collection — see below.

---

## Files / media (offline + online)

`VorzBlobStore` stores arbitrary-size binary blobs alongside your regular
data, encrypted chunk-by-chunk (default 64 KiB) so a large file never needs
to sit fully in memory to be written or read. It's built for the common
"cache what I've downloaded from my backend, work offline" pattern —
sync state is just metadata you set as your own upload/download logic runs.

```dart
final store = await VorzStore.open(name: 'app');
final blobs = await VorzBlobStore.open(store, maxTotalBytes: 200 * 1024 * 1024);

// Download and cache (e.g. inside your own http streaming call):
await blobs.putStream(
  'avatar:u1',
  httpResponse.stream,
  mimeType: 'image/jpeg',
  remoteUrl: 'https://api.example.com/avatars/u1.jpg',
  syncState: BlobSyncState.synced,
);

// Or from bytes you already have:
await blobs.putBytes('doc:42', fileBytes, mimeType: 'application/pdf');

// Read back (offline-safe — no network involved):
final bytes = await blobs.getBytes('avatar:u1');
final stream = blobs.getStream('doc:42'); // for large files

// Know a file exists on your backend before downloading it:
await blobs.registerRemote('doc:99', size: 1_048_576, remoteUrl: '...');
```

With `maxTotalBytes` set, the least-recently-used **re-fetchable** blobs
(`BlobSyncState.synced` or anything with a `remoteUrl`) are evicted first
when the cap is exceeded. Blobs with `BlobSyncState.local` and no
`remoteUrl` — i.e. not backed up anywhere yet — are never auto-evicted.

Your backend database stays the source of truth; `VorzBlobStore` is purely
the on-device cache/offline copy.

---

## Security

| Piece | Where |
|-------|--------|
| DEK (256-bit) | Keychain / Keystore via `flutter_secure_storage` |
| Values | AES-256-GCM, unique nonce per record |
| AAD | `dbName\|collection\|key\|schemaVersion` |
| Index (`.idx`) | Same compress+encrypt pipeline as record values — indexed field values are not plaintext on disk |
| Blobs (`VorzBlobStore`) | AES-256-GCM per 64 KiB chunk, unique nonce per chunk, defaults to the store's own DEK |

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

## Linter (best practices)

Use [`vorzela_store_lint`](packages/vorzela_store_lint) with `custom_lint` ^0.8.1
so durable, reboot-safe usage stays correct:

- never put `VorzStore.open(directory:)` under tmp / cache dirs
- no `openMemory` in app code (tests only)
- large `bytes` → `VorzBlobStore`, not document collections
- prefer `store.models()` over manual `collection(fromJson:)`
- after `wipeKeys()`, `close()` before reopening

See [packages/vorzela_store_lint/README.md](packages/vorzela_store_lint/README.md).

---

## Tests

```bash
cd vorzela_store && flutter test
```
