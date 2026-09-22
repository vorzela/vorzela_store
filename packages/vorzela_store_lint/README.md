# vorzela_store_lint

[`custom_lint`](https://pub.dev/packages/custom_lint) rules for
[vorzela_store](https://github.com/vorzela/vorzela_store) best practices.

**Durable storage:** `VorzStore.open()` defaults to **Application Support**, which
survives phone reboots. Never point production stores at temporary or cache
directories — OS cleanup will erase your data.

## Install

In your app `pubspec.yaml`:

```yaml
dev_dependencies:
  custom_lint: ^0.8.1
  vorzela_store_lint:
    git:
      url: https://github.com/vorzela/vorzela_store.git
      path: packages/vorzela_store_lint
```

In `analysis_options.yaml`:

```yaml
analyzer:
  plugins:
    - custom_lint

custom_lint:
  rules:
    - avoid_temporary_directory_for_vorz_store
    - avoid_vorz_store_open_memory_in_app
    - prefer_vorz_blob_store_for_bytes
    - prefer_store_models_helper
    - prefer_wipe_keys_then_close
```

Run:

```bash
dart run custom_lint
```

## Rules

| Rule | What it catches |
|------|-----------------|
| `avoid_temporary_directory_for_vorz_store` | `VorzStore.open(directory: tmp/cache/...)` |
| `avoid_vorz_store_open_memory_in_app` | `VorzStore.openMemory` outside `test/` |
| `prefer_vorz_blob_store_for_bytes` | `$set('bytes', …)` / `put` with `'bytes'` maps |
| `prefer_store_models_helper` | `collection(..., fromJson: …)` — prefer `models` |
| `prefer_wipe_keys_then_close` | `wipeKeys()` without `close()` in the same function |

Disable a rule:

```yaml
custom_lint:
  rules:
    - prefer_store_models_helper: false
```

## License

MIT
