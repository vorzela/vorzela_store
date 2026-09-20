import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'codec.dart';
import 'engine.dart';

class _Slot {
  _Slot({required this.offset, required this.length});

  int offset;
  int length;
}

/// FIFO async mutex — see class doc on [FileEngine].
class _Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final gate = Completer<void>();
    final previous = _tail;
    _tail = gate.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        gate.complete();
      }
    });
  }
}

/// Pure-Dart durable engine: append/slot-reuse `.dat` + crash-safe `.idx`.
///
/// Durability rules (the usual hand-rolled-DB footguns we close here):
/// 1. Per-collection async lock — no interleaved puts at await points.
/// 2. Flush `.dat` before committing `.idx`.
/// 3. Replace `.idx` via write-temp + rename (POSIX atomic); never
///    delete-then-rename (crash window with no index).
/// 4. Data + equality indexes share one index commit on put/delete/putAll.
/// 5. Logical `fileSize` comes from the index (trailing crash junk ignored).
/// 6. Compact uses rename-over / backup dance — never delete live `.dat` first.
class FileEngine implements StoreEngine {
  FileEngine(
    this.root, {
    this.autoCompactRatio = 0.25,
    this.autoCompactMinDeadBytes = 4 * 1024 * 1024,
  });

  final Directory root;
  final double autoCompactRatio;
  final int autoCompactMinDeadBytes;

  final Map<String, Map<String, _Slot>> _entries = {};
  final Map<String, List<String>> _indexFields = {};
  final Map<String, Map<String, Map<String, String>>> _docIndexes = {};
  final Map<String, Map<String, Map<String, Set<String>>>> _eq = {};
  final Map<String, int> _deadBytes = {};
  final Map<String, int> _fileSize = {};
  final Map<String, RandomAccessFile> _rafs = {};
  final Map<String, _Mutex> _locks = {};

  StoreCodec? _indexCodec;

  static const int _lenHeader = 4;

  File _dat(String c) => File(p.join(root.path, '$c.dat'));
  File _idx(String c) => File(p.join(root.path, '$c.idx'));
  File _idxTmp(String c) => File(p.join(root.path, '$c.idx.tmp'));

  void attachIndexCodec(StoreCodec codec) {
    _indexCodec = codec;
  }

  _Mutex _lockFor(String collection) =>
      _locks.putIfAbsent(collection, () => _Mutex());

  Future<T> _locked<T>(String collection, Future<T> Function() action) =>
      _lockFor(collection).run(action);

  /// Atomically replace [target] with [tmp] (tmp must already be fully written
  /// and flushed). On POSIX, `rename` replaces without a delete-first window.
  /// On Windows, rename-over is not allowed — we rename the live file aside,
  /// then rename tmp into place, restoring on failure.
  Future<void> _atomicReplace(File tmp, File target) async {
    if (Platform.isWindows) {
      final bak = File('${target.path}.bak');
      if (await bak.exists()) await bak.delete();
      if (await target.exists()) {
        await target.rename(bak.path);
      }
      try {
        await tmp.rename(target.path);
        if (await bak.exists()) await bak.delete();
      } catch (_) {
        if (await bak.exists() && !await target.exists()) {
          await bak.rename(target.path);
        }
        rethrow;
      }
      return;
    }
    // Linux/macOS/iOS/Android: rename onto existing path is atomic replace.
    await tmp.rename(target.path);
  }

  @override
  Future<void> openCollection(
    String name, {
    List<String> indexFields = const [],
  }) {
    return _locked(name, () async {
      await root.create(recursive: true);
      _indexFields[name] = List.of(indexFields);
      _entries.putIfAbsent(name, () => {});
      _docIndexes.putIfAbsent(name, () => {});
      _eq.putIfAbsent(name, () => {
            for (final f in indexFields) f: <String, Set<String>>{},
          });
      _deadBytes.putIfAbsent(name, () => 0);
      _fileSize.putIfAbsent(name, () => 0);

      await _loadIndex(name);

      final dat = _dat(name);
      if (!await dat.exists()) {
        await dat.create(recursive: true);
      }

      // Drop slots that point past EOF (truncated data file after crash/copy).
      final diskLen = await dat.length();
      final entries = _entries[name]!;
      final dead = <String>[];
      for (final e in entries.entries) {
        if (e.value.offset + e.value.length > diskLen) {
          dead.add(e.key);
        }
      }
      for (final k in dead) {
        final slot = entries.remove(k);
        if (slot != null) {
          _deadBytes[name] = (_deadBytes[name] ?? 0) + slot.length;
        }
        final old = _docIndexes[name]?.remove(k);
        if (old != null) {
          _applyIndexUnlocked(name, k, oldValues: old, newValues: null);
        }
      }
      if (dead.isNotEmpty) {
        await _commitIndex(name);
      }

      // Reuse logical size from index — ignore trailing junk past last commit.
      // (A crash after append but before idx commit leaves orphan bytes; the
      // next append must continue from the last *committed* end, not EOF.)
      var logical = _fileSize[name] ?? 0;
      for (final s in entries.values) {
        final end = s.offset + s.length;
        if (end > logical) logical = end;
      }
      if (logical > diskLen) logical = diskLen;
      _fileSize[name] = logical;

      // Avoid leaking a second handle if openCollection is called again.
      await _rafs.remove(name)?.close();
      _rafs[name] = await dat.open(mode: FileMode.append);
    });
  }

  List<int> _indexAad(String name) => 'vorzela_store_index|$name'.codeUnits;

  Future<void> _loadIndex(String name) async {
    final idx = _idx(name);
    final tmp = _idxTmp(name);
    if (!await idx.exists()) {
      _entries[name] = {};
      _docIndexes[name] = {};
      _deadBytes[name] = 0;
      _fileSize[name] = 0;
      if (await tmp.exists()) await tmp.delete();
      return;
    }
    final raw = await idx.readAsBytes();
    if (raw.isEmpty) {
      _entries[name] = {};
      _fileSize[name] = 0;
      if (await tmp.exists()) await tmp.delete();
      return;
    }

    final codec = _indexCodec;
    final Uint8List jsonBytes = codec != null
        ? await codec.decodeRaw(Uint8List.fromList(raw), aad: _indexAad(name))
        : Uint8List.fromList(raw);

    final map = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
    final entries = <String, _Slot>{};
    final rawEntries = map['entries'] as Map<String, dynamic>? ?? {};
    for (final e in rawEntries.entries) {
      final m = e.value as Map<String, dynamic>;
      entries[e.key] = _Slot(
        offset: m['o'] as int,
        length: m['l'] as int,
      );
    }
    _entries[name] = entries;
    _deadBytes[name] = map['deadBytes'] as int? ?? 0;
    _fileSize[name] = map['fileSize'] as int? ?? 0;

    final docs = <String, Map<String, String>>{};
    final rawDocs = map['docIndexes'] as Map<String, dynamic>? ?? {};
    for (final e in rawDocs.entries) {
      docs[e.key] = {
        for (final f in (e.value as Map).entries)
          f.key.toString(): f.value.toString(),
      };
    }
    _docIndexes[name] = docs;

    final eq = <String, Map<String, Set<String>>>{
      for (final f in _indexFields[name]!) f: <String, Set<String>>{},
    };
    for (final e in docs.entries) {
      for (final f in e.value.entries) {
        eq.putIfAbsent(f.key, () => {});
        eq[f.key]!.putIfAbsent(f.value, () => {}).add(e.key);
      }
    }
    _eq[name] = eq;

    if (await tmp.exists()) await tmp.delete();
  }

  Future<void> _commitIndex(String name) async {
    final payload = <String, dynamic>{
      'entries': {
        for (final e in _entries[name]!.entries)
          e.key: {'o': e.value.offset, 'l': e.value.length},
      },
      'docIndexes': _docIndexes[name],
      'deadBytes': _deadBytes[name] ?? 0,
      'fileSize': _fileSize[name] ?? 0,
    };
    final jsonBytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final codec = _indexCodec;
    final outBytes = codec != null
        ? await codec.encodeRaw(jsonBytes, aad: _indexAad(name))
        : jsonBytes;

    final tmp = _idxTmp(name);
    await tmp.writeAsBytes(outBytes, flush: true);
    await _atomicReplace(tmp, _idx(name));
  }

  Future<void> _flushDat(String name) async {
    final raf = _rafs[name];
    if (raf != null) await raf.flush();
  }

  List<int> _encodeLength(int n) {
    final b = ByteData(4)..setUint32(0, n, Endian.big);
    return b.buffer.asUint8List();
  }

  int _decodeLength(Uint8List b) =>
      ByteData.sublistView(b).getUint32(0, Endian.big);

  void _applyIndexUnlocked(
    String collection,
    String key, {
    Map<String, String>? oldValues,
    Map<String, String>? newValues,
  }) {
    final eq = _eq[collection];
    if (eq == null) return;
    if (oldValues != null) {
      for (final e in oldValues.entries) {
        eq[e.key]?[e.value]?.remove(key);
      }
    }
    if (newValues != null) {
      _docIndexes[collection]![key] = Map.of(newValues);
      for (final e in newValues.entries) {
        eq.putIfAbsent(e.key, () => {});
        eq[e.key]!.putIfAbsent(e.value, () => {}).add(key);
      }
    } else if (oldValues != null) {
      _docIndexes[collection]?.remove(key);
    }
  }

  @override
  Future<void> put(
    String collection,
    String key,
    Uint8List record, {
    Map<String, String>? oldIndex,
    Map<String, String>? newIndex,
  }) {
    return _locked(collection, () async {
      await _putNoCommit(collection, key, record);
      if (oldIndex != null || newIndex != null) {
        _applyIndexUnlocked(
          collection,
          key,
          oldValues: oldIndex,
          newValues: newIndex,
        );
      }
      await _flushDat(collection);
      await _commitIndex(collection);
      await _compactIfNeeded(collection);
    });
  }

  Future<RandomAccessFile> _appendRaf(String collection) async {
    var raf = _rafs[collection];
    if (raf != null) {
      try {
        await raf.position();
        return raf;
      } catch (_) {
        _rafs.remove(collection);
        try {
          await raf.close();
        } catch (_) {}
      }
    }
    raf = await _dat(collection).open(mode: FileMode.append);
    _rafs[collection] = raf;
    return raf;
  }

  Future<void> _writeAt(
    String collection,
    int offset,
    Uint8List record,
  ) async {
    final raf = await _appendRaf(collection);
    await raf.setPosition(offset);
    await raf.writeFrom(_encodeLength(record.length));
    await raf.writeFrom(record);
    await raf.flush();
  }

  @override
  Future<Uint8List?> get(String collection, String key) {
    return _locked(collection, () => _readRecord(collection, key));
  }

  Future<Uint8List?> _readRecord(String collection, String key) async {
    final slot = _entries[collection]?[key];
    if (slot == null) return null;
    final raf = await _appendRaf(collection);
    return _readSlot(raf, slot);
  }

  Future<Uint8List?> _readSlot(RandomAccessFile raf, _Slot slot) async {
    await raf.setPosition(slot.offset);
    final lenBytes = await raf.read(4);
    if (lenBytes.length < 4) return null;
    final len = _decodeLength(Uint8List.fromList(lenBytes));
    if (len < 0 || len > slot.length - _lenHeader) return null;
    final data = await raf.read(len);
    if (data.length < len) return null;
    return Uint8List.fromList(data);
  }

  @override
  Future<void> delete(
    String collection,
    String key, {
    Map<String, String>? oldIndex,
  }) {
    return _locked(collection, () async {
      final slot = _entries[collection]?.remove(key);
      if (slot != null) {
        _deadBytes[collection] = (_deadBytes[collection] ?? 0) + slot.length;
      }
      if (oldIndex != null) {
        _applyIndexUnlocked(
          collection,
          key,
          oldValues: oldIndex,
          newValues: null,
        );
      } else {
        final had = _docIndexes[collection]?.remove(key);
        if (had != null) {
          _applyIndexUnlocked(
            collection,
            key,
            oldValues: had,
            newValues: null,
          );
        }
      }
      await _commitIndex(collection);
      await _compactIfNeeded(collection);
    });
  }

  @override
  Future<void> putAll(
    String collection,
    Map<String, Uint8List> records, {
    Map<String, Map<String, String>?>? oldIndexes,
    Map<String, Map<String, String>?>? newIndexes,
  }) {
    return _locked(collection, () async {
      for (final e in records.entries) {
        await _putNoCommit(collection, e.key, e.value);
        final oldIdx = oldIndexes?[e.key];
        final newIdx = newIndexes?[e.key];
        if (oldIdx != null || newIdx != null) {
          _applyIndexUnlocked(
            collection,
            e.key,
            oldValues: oldIdx,
            newValues: newIdx,
          );
        }
      }
      await _flushDat(collection);
      await _commitIndex(collection);
      await _compactIfNeeded(collection);
    });
  }

  Future<void> _putNoCommit(
    String collection,
    String key,
    Uint8List record,
  ) async {
    final entries = _entries[collection]!;
    final old = entries[key];
    final frameLen = _lenHeader + record.length;

    if (old != null && frameLen <= old.length) {
      await _writeAt(collection, old.offset, record);
      final freed = old.length - frameLen;
      if (freed > 0) {
        _deadBytes[collection] = (_deadBytes[collection] ?? 0) + freed;
      }
      old.length = frameLen;
      return;
    }

    if (old != null) {
      _deadBytes[collection] = (_deadBytes[collection] ?? 0) + old.length;
    }
    final raf = await _appendRaf(collection);
    final offset = _fileSize[collection] ?? 0;
    await raf.setPosition(offset);
    await raf.writeFrom(_encodeLength(record.length));
    await raf.writeFrom(record);
    entries[key] = _Slot(offset: offset, length: frameLen);
    _fileSize[collection] = offset + frameLen;
  }

  Future<void> _compactIfNeeded(String collection) async {
    final dead = _deadBytes[collection] ?? 0;
    final size = _fileSize[collection] ?? 0;
    if (size == 0) return;
    if (dead >= autoCompactMinDeadBytes || dead / size >= autoCompactRatio) {
      await _compactOne(collection);
    }
  }

  @override
  Future<List<String>> keys(String collection) {
    return _locked(
      collection,
      () async => _entries[collection]?.keys.toList() ?? [],
    );
  }

  @override
  Future<List<String>> keysWhereEq(
    String collection,
    String field,
    String value,
  ) {
    return _locked(collection, () async {
      final set = _eq[collection]?[field]?[value];
      return set?.toList() ?? [];
    });
  }

  @override
  Future<void> setIndexValues(
    String collection,
    String key, {
    Map<String, String>? oldValues,
    Map<String, String>? newValues,
    bool commit = true,
  }) {
    return _locked(collection, () async {
      _applyIndexUnlocked(
        collection,
        key,
        oldValues: oldValues,
        newValues: newValues,
      );
      if (commit) await _commitIndex(collection);
    });
  }

  @override
  Future<Map<String, String>?> indexValues(
    String collection,
    String key,
  ) {
    return _locked(collection, () async {
      final v = _docIndexes[collection]?[key];
      return v == null ? null : Map.of(v);
    });
  }

  @override
  Future<void> compact([String? collection]) async {
    final names = collection == null
        ? _entries.keys.toList()
        : <String>[collection];
    for (final name in names) {
      await _locked(name, () => _compactOne(name));
    }
  }

  Future<void> _compactOne(String name) async {
    final entries = _entries[name];
    if (entries == null) return;

    await _rafs.remove(name)?.close();

    final oldDat = _dat(name);
    if (!await oldDat.exists()) {
      _rafs[name] = await oldDat.open(mode: FileMode.append);
      return;
    }

    final readRaf = await oldDat.open(mode: FileMode.read);
    final newDat = File(p.join(root.path, '$name.dat.new'));
    if (await newDat.exists()) await newDat.delete();
    final out = await newDat.open(mode: FileMode.write);
    final newEntries = <String, _Slot>{};
    var cursor = 0;

    try {
      for (final e in entries.entries) {
        final bytes = await _readSlot(readRaf, e.value);
        if (bytes == null) continue;
        final frameLen = _lenHeader + bytes.length;
        await out.writeFrom(_encodeLength(bytes.length));
        await out.writeFrom(bytes);
        newEntries[e.key] = _Slot(offset: cursor, length: frameLen);
        cursor += frameLen;
      }
      await out.flush();
    } finally {
      await out.close();
      await readRaf.close();
    }

    // Swap data file first (atomic replace), then commit index that points
    // at the new layout. Never delete the live .dat before the new one is
    // in place — that was a crash window with no data file at all.
    await _atomicReplace(newDat, oldDat);

    _entries[name] = newEntries;
    _deadBytes[name] = 0;
    _fileSize[name] = cursor;
    _rafs[name] = await oldDat.open(mode: FileMode.append);
    await _commitIndex(name);
  }

  @override
  Future<void> close() async {
    for (final raf in _rafs.values) {
      try {
        await raf.close();
      } catch (_) {}
    }
    _rafs.clear();
  }

  @override
  Future<int> dataFileSize(String collection) async =>
      _fileSize[collection] ?? 0;

  @override
  Future<int> deadBytes(String collection) async =>
      _deadBytes[collection] ?? 0;
}
