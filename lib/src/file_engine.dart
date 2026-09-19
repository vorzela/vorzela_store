import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'engine.dart';

class _Slot {
  _Slot({required this.offset, required this.length});

  int offset;
  int length;
}

/// Pure-Dart durable engine: append/slot-reuse `.dat` + crash-safe `.idx`.
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

  static const int _lenHeader = 4;

  File _dat(String c) => File(p.join(root.path, '$c.dat'));
  File _idx(String c) => File(p.join(root.path, '$c.idx'));
  File _idxTmp(String c) => File(p.join(root.path, '$c.idx.tmp'));

  @override
  Future<void> openCollection(
    String name, {
    List<String> indexFields = const [],
  }) async {
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
    _fileSize[name] = await dat.length();
    _rafs[name] = await dat.open(mode: FileMode.append);
  }

  Future<void> _loadIndex(String name) async {
    final idx = _idx(name);
    final tmp = _idxTmp(name);
    // Prefer committed idx; if only tmp exists (crash), ignore tmp.
    if (!await idx.exists()) {
      _entries[name] = {};
      _docIndexes[name] = {};
      _deadBytes[name] = 0;
      return;
    }
    final text = await idx.readAsString();
    if (text.isEmpty) {
      _entries[name] = {};
      return;
    }
    final map = jsonDecode(text) as Map<String, dynamic>;
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

    final docs = <String, Map<String, String>>{};
    final rawDocs = map['docIndexes'] as Map<String, dynamic>? ?? {};
    for (final e in rawDocs.entries) {
      docs[e.key] = {
        for (final f in (e.value as Map).entries)
          f.key.toString(): f.value.toString(),
      };
    }
    _docIndexes[name] = docs;

    // Rebuild equality sets from docIndexes.
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

    if (await tmp.exists()) {
      await tmp.delete();
    }
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
    final tmp = _idxTmp(name);
    final idx = _idx(name);
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    if (await idx.exists()) {
      await idx.delete();
    }
    await tmp.rename(idx.path);
  }

  Future<void> _flushDat(String name) async {
    final raf = _rafs[name];
    if (raf != null) {
      await raf.flush();
    }
  }

  List<int> _encodeLength(int n) {
    final b = ByteData(4)..setUint32(0, n, Endian.big);
    return b.buffer.asUint8List();
  }

  int _decodeLength(Uint8List b) =>
      ByteData.sublistView(b).getUint32(0, Endian.big);

  @override
  Future<void> put(String collection, String key, Uint8List record) async {
    final entries = _entries[collection]!;
    final old = entries[key];
    final frameLen = _lenHeader + record.length;

    if (old != null && frameLen <= old.length) {
      // In-place overwrite without truncating the data file.
      await _writeAt(collection, old.offset, record);
      final freed = old.length - frameLen;
      if (freed > 0) {
        _deadBytes[collection] = (_deadBytes[collection] ?? 0) + freed;
      }
      old.length = frameLen;
    } else {
      if (old != null) {
        _deadBytes[collection] =
            (_deadBytes[collection] ?? 0) + old.length;
      }
      final raf = await _appendRaf(collection);
      final offset = _fileSize[collection] ?? await _dat(collection).length();
      await raf.setPosition(offset);
      await raf.writeFrom(_encodeLength(record.length));
      await raf.writeFrom(record);
      await raf.flush();
      entries[key] = _Slot(offset: offset, length: frameLen);
      _fileSize[collection] = offset + frameLen;
    }

    await _commitIndex(collection);
    await _maybeAutoCompact(collection);
  }

  Future<RandomAccessFile> _appendRaf(String collection) async {
    var raf = _rafs[collection];
    if (raf == null) {
      raf = await _dat(collection).open(mode: FileMode.append);
      _rafs[collection] = raf;
    }
    return raf;
  }

  /// Write a length-prefixed record at [offset] without truncating the file.
  Future<void> _writeAt(
    String collection,
    int offset,
    Uint8List record,
  ) async {
    // Use append mode so open does not truncate, then seek.
    final raf = await _dat(collection).open(mode: FileMode.append);
    try {
      await raf.setPosition(offset);
      await raf.writeFrom(_encodeLength(record.length));
      await raf.writeFrom(record);
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  @override
  Future<Uint8List?> get(String collection, String key) async {
    final slot = _entries[collection]?[key];
    if (slot == null) return null;
    final raf = await _dat(collection).open(mode: FileMode.read);
    try {
      await raf.setPosition(slot.offset);
      final lenBytes = await raf.read(4);
      if (lenBytes.length < 4) return null;
      final len = _decodeLength(Uint8List.fromList(lenBytes));
      if (len < 0 || len > slot.length - _lenHeader) {
        return null;
      }
      final data = await raf.read(len);
      if (data.length < len) return null;
      return Uint8List.fromList(data);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> delete(String collection, String key) async {
    final slot = _entries[collection]?.remove(key);
    if (slot != null) {
      _deadBytes[collection] =
          (_deadBytes[collection] ?? 0) + slot.length;
    }
    await _commitIndex(collection);
    await _maybeAutoCompact(collection);
  }

  @override
  Future<void> putAll(String collection, Map<String, Uint8List> records) async {
    for (final e in records.entries) {
      // Batch without per-key compact; commit index once at end.
      await _putNoCommit(collection, e.key, e.value);
    }
    await _flushDat(collection);
    await _commitIndex(collection);
    await _maybeAutoCompact(collection);
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
    final offset = _fileSize[collection] ?? await _dat(collection).length();
    await raf.setPosition(offset);
    await raf.writeFrom(_encodeLength(record.length));
    await raf.writeFrom(record);
    entries[key] = _Slot(offset: offset, length: frameLen);
    _fileSize[collection] = offset + frameLen;
  }

  Future<void> _maybeAutoCompact(String collection) async {
    final dead = _deadBytes[collection] ?? 0;
    final size = _fileSize[collection] ?? 0;
    if (size == 0) return;
    if (dead >= autoCompactMinDeadBytes ||
        dead / size >= autoCompactRatio) {
      await compact(collection);
    }
  }

  @override
  Future<List<String>> keys(String collection) async =>
      _entries[collection]?.keys.toList() ?? [];

  @override
  Future<List<String>> keysWhereEq(
    String collection,
    String field,
    String value,
  ) async {
    final set = _eq[collection]?[field]?[value];
    return set?.toList() ?? [];
  }

  @override
  Future<void> setIndexValues(
    String collection,
    String key, {
    Map<String, String>? oldValues,
    Map<String, String>? newValues,
  }) async {
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
    } else {
      _docIndexes[collection]?.remove(key);
    }
    // Index persistence is part of put/delete commit; callers that only
    // update indexes after put should call commit — collection layer does.
    await _commitIndex(collection);
  }

  @override
  Future<Map<String, String>?> indexValues(
    String collection,
    String key,
  ) async {
    final v = _docIndexes[collection]?[key];
    return v == null ? null : Map.of(v);
  }

  @override
  Future<void> compact([String? collection]) async {
    final names = collection == null
        ? _entries.keys.toList()
        : <String>[collection];
    for (final name in names) {
      await _compactOne(name);
    }
  }

  Future<void> _compactOne(String name) async {
    final entries = _entries[name];
    if (entries == null) return;

    // Close append handle before rewriting.
    await _rafs.remove(name)?.close();

    final newDat = File(p.join(root.path, '$name.dat.new'));
    if (await newDat.exists()) await newDat.delete();
    final out = await newDat.open(mode: FileMode.write);
    final newEntries = <String, _Slot>{};
    var cursor = 0;

    try {
      for (final e in entries.entries) {
        final bytes = await get(name, e.key);
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
    }

    final oldDat = _dat(name);
    if (await oldDat.exists()) await oldDat.delete();
    await newDat.rename(oldDat.path);

    _entries[name] = newEntries;
    _deadBytes[name] = 0;
    _fileSize[name] = cursor;
    _rafs[name] = await oldDat.open(mode: FileMode.append);
    await _commitIndex(name);
  }

  @override
  Future<void> close() async {
    for (final raf in _rafs.values) {
      await raf.close();
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
