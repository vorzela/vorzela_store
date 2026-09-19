/// Durable encrypted NoSQL document store for Flutter.
///
/// CBOR + zlib + AES-GCM on disk. No Hive / SQL.
library;

export 'src/codec.dart';
export 'src/collection.dart';
export 'src/engine.dart';
export 'src/file_engine.dart';
export 'src/memory_engine.dart';
export 'src/query.dart';
export 'src/secure_key.dart';
export 'src/store.dart';
