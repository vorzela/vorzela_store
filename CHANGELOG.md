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
