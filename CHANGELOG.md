## 0.0.4

### Added
- **`packages/vorzela_store_lint`** — `custom_lint` rules so stores stay
  reboot-safe (Application Support, no tmp/cache), prefer `VorzBlobStore`
  for bytes, `models()` helper, and `wipeKeys` → `close`.

## 0.0.3

**Fixes (durability / crash windows)**
- Index replace no longer deletes the live `.idx` before renaming the temp
  file into place (POSIX atomic rename-over; Windows backup-then-rename).
  The old delete-then-rename left a crash window with **no index on disk**.
- Compact no longer deletes the live `.dat` before the new file is in place;
  uses the same atomic replace helper.
- `put` / `delete` / `putAll` now commit **ciphertext + equality indexes in
  one** index flush (closes the window where data was durable but indexes
  were still stale after a crash).
- On open, logical `fileSize` is restored from the committed index (not raw
  EOF), so orphan trailing bytes after a crash-before-idx-commit do not
  shift later appends. Slots past EOF are dropped.
- Re-opening a collection closes any prior RAF first (FD leak).
- Blob overwrite uses rename-over on POSIX instead of delete-then-rename.

## 0.0.2

**Fixes**
- `FileEngine` operations on a collection are now serialized with a
  per-collection async lock. Previously, concurrent `put`/`delete`/`compact`
  calls (e.g. `Future.wait([...])`) could interleave across `await` points
  and corrupt the `.dat` file or lose index updates.
- `put`/`get` reuse a persistent file handle instead of opening and closing
  the `.dat` file on every call.
- `VorzCollection.putAll()` now does a single index-file commit for the
  whole batch instead of one full index rewrite per document.
- The `.idx` index file is now encrypted (same compress+encrypt pipeline as
  record values) instead of being written as plaintext JSON — previously
  indexed field values were readable straight off disk even for an
  "encrypted" store, and remained so after `wipeKeys()`.
- `whereEq(null)` now throws instead of silently falling back to a full scan.

**Added**
- `VorzBlobStore`: a streaming, chunk-encrypted store for files/media too
  large or write-heavy for the document engine — for the "cache what I
  downloaded from my backend, work offline" use case. Defaults to the
  store's own DEK, supports `putStream`/`getStream` for large files without
  holding them fully in memory, `registerRemote` for backend-known-but-not-
  downloaded files, and optional LRU eviction against a total-size cap that
  never touches unsynced local-only data.

## 0.0.1

- Initial release: durable encrypted document store
- Pure-Dart `.dat` / `.idx` engine (no Hive/SQL)
- CBOR + zlib + AES-256-GCM
- Slot reuse, auto-compact, equality indexes, watch streams
- `vorzela_json` model helpers
