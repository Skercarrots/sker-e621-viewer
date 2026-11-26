import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Metadata describing an encrypted recovery snapshot stored by [LocalDataVault].
class VaultSnapshotInfo {
  final String id;
  final String reason;
  final DateTime createdAt;
  final int schemaVersion;
  final String appVersion;
  final int entryCount;

  const VaultSnapshotInfo({
    required this.id,
    required this.reason,
    required this.createdAt,
    required this.schemaVersion,
    required this.appVersion,
    required this.entryCount,
  });

  String get displayReason {
    switch (reason) {
      case 'pre_update':
        return 'Pre-update backup';
      case 'pre_import':
        return 'Pre-import safety backup';
      case 'manual':
        return 'Manual snapshot';
      default:
        return reason;
    }
  }
}

/// App-private, AES-256-GCM encrypted, crash-safe key-value vault for all
/// structured user data (boards, ref canvases, favorite tags, follows,
/// blacklist rules, guest favorites, and preferences).
///
/// Account credentials (`username`, `apiKey`) remain exclusively in
/// [FlutterSecureStorage], alongside the 256-bit vault master key.
class LocalDataVault {
  static const int currentSchemaVersion = 1;
  static const String currentAppVersion = '1.0.0+1';
  static const String masterKeyStorageKey = 'sker_vault_master_key_v1';

  static const int maxPreUpdateSnapshots = 3;
  static const int maxPreImportSnapshots = 2;
  static const int maxTotalSnapshots = 5;

  static const String _primaryFileName = 'vault_data.enc';
  static const String _backupFileName = 'vault_data.enc.bak';
  static const String _tempFileName = 'vault_data.enc.tmp';

  final FlutterSecureStorage _keyStorage;
  final Directory? _baseDirectoryOverride;
  final String _appVersion;
  final AesGcm _aesGcm = AesGcm.with256bits();
  final Random _random = Random.secure();

  late Directory _vaultDir;
  late Directory _snapshotsDir;
  SecretKey? _masterKey;

  Map<String, String> _entries = {};
  int _schemaVersion = 0;
  String _storedAppVersion = '';
  bool _isInitialized = false;
  bool _recoveredFromBackup = false;
  String? _lastRecoverySource;
  int _snapshotCounter = 0;

  Future<void> _serialChain = Future<void>.value();

  LocalDataVault({
    FlutterSecureStorage? keyStorage,
    Directory? baseDirectory,
    String appVersion = currentAppVersion,
  })  : _keyStorage = keyStorage ?? const FlutterSecureStorage(),
        _baseDirectoryOverride = baseDirectory,
        _appVersion = appVersion;

  bool get isInitialized => _isInitialized;
  int get schemaVersion => _schemaVersion;
  String get storedAppVersion => _storedAppVersion;
  String get currentRuntimeAppVersion => _appVersion;
  bool get recoveredFromBackup => _recoveredFromBackup;
  String? get lastRecoverySource => _lastRecoverySource;
  int get entryCount => _entries.length;
  Directory get vaultDirectory => _vaultDir;

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final next = _serialChain.then((_) => action());
    _serialChain = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  /// Initializes the vault directory, master key, and loads encrypted state.
  /// Automatically falls back to `.bak` or the newest valid snapshot if the
  /// primary file is damaged.
  Future<void> init() async {
    if (_isInitialized) return;

    await _synchronized(() async {
      if (_isInitialized) return;

      final baseDir = _baseDirectoryOverride ??
          Directory(
            '${(await getApplicationSupportDirectory()).path}'
            '${Platform.pathSeparator}vault',
          );
      _vaultDir = baseDir;
      _snapshotsDir = Directory(
        '${_vaultDir.path}${Platform.pathSeparator}snapshots',
      );

      await _vaultDir.create(recursive: true);
      await _snapshotsDir.create(recursive: true);

      _masterKey = await _loadOrCreateMasterKey();

      final primaryFile = _file(_primaryFileName);
      final backupFile = _file(_backupFileName);

      if (await primaryFile.exists()) {
        final loaded = await _tryLoadFromFile(primaryFile);
        if (loaded != null) {
          _applyPayload(loaded);
          _isInitialized = true;
          return;
        }

        // Primary exists but could not be decrypted/parsed: try .bak first
        if (await backupFile.exists()) {
          final fromBak = await _tryLoadFromFile(backupFile);
          if (fromBak != null) {
            _applyPayload(fromBak);
            _recoveredFromBackup = true;
            _lastRecoverySource = _backupFileName;
            await _persistCurrentStateLocked();
            _isInitialized = true;
            return;
          }
        }

        // Try newest valid snapshot
        final recoveredSnap = await _tryLoadNewestValidSnapshot();
        if (recoveredSnap != null) {
          _applyPayload(recoveredSnap.$1);
          _recoveredFromBackup = true;
          _lastRecoverySource = recoveredSnap.$2;
          await _persistCurrentStateLocked();
          _isInitialized = true;
          return;
        }

        throw StateError(
          'Vault primary file is corrupted and no valid backup or snapshot could be recovered.',
        );
      } else if (await backupFile.exists()) {
        final fromBak = await _tryLoadFromFile(backupFile);
        if (fromBak != null) {
          _applyPayload(fromBak);
          _recoveredFromBackup = true;
          _lastRecoverySource = _backupFileName;
          await _persistCurrentStateLocked();
          _isInitialized = true;
          return;
        }
      }

      // Fresh install (no primary or backup yet)
      _entries = {};
      _schemaVersion = 0;
      _storedAppVersion = _appVersion;
      _isInitialized = true;
    });
  }

  Future<SecretKey> _loadOrCreateMasterKey() async {
    final existing = await _keyStorage.read(key: masterKeyStorageKey);
    if (existing != null && existing.isNotEmpty) {
      try {
        final bytes = base64Decode(existing);
        if (bytes.length == 32) {
          return SecretKey(bytes);
        }
      } catch (e) {
        debugPrint('Invalid vault master key in storage: $e');
      }
    }

    final keyBytes = Uint8List(32);
    for (int i = 0; i < keyBytes.length; i++) {
      keyBytes[i] = _random.nextInt(256);
    }
    await _keyStorage.write(
      key: masterKeyStorageKey,
      value: base64Encode(keyBytes),
    );
    return SecretKey(keyBytes);
  }

  File _file(String name) => File('${_vaultDir.path}${Platform.pathSeparator}$name');

  void _applyPayload(_VaultPlainPayload payload) {
    _entries = Map<String, String>.from(payload.entries);
    _schemaVersion = payload.schemaVersion;
    _storedAppVersion = payload.appVersion;
  }

  Future<_VaultPlainPayload?> _tryLoadFromFile(File file) async {
    try {
      final rawBytes = await file.readAsBytes();
      if (rawBytes.isEmpty) return null;
      final envelope = jsonDecode(utf8.decode(rawBytes));
      if (envelope is! Map<String, dynamic>) return null;
      return await _decryptEnvelope(envelope);
    } catch (e) {
      debugPrint('Failed to load vault file ${file.path}: $e');
      return null;
    }
  }

  Future<(_VaultPlainPayload, String)?> _tryLoadNewestValidSnapshot() async {
    try {
      final files = await _listSnapshotFilesSorted();
      for (final file in files) {
        final loaded = await _tryLoadFromFile(file);
        if (loaded != null) {
          return (loaded, file.uri.pathSegments.last);
        }
      }
    } catch (e) {
      debugPrint('Error scanning snapshots for recovery: $e');
    }
    return null;
  }

  Future<_VaultPlainPayload?> _decryptEnvelope(
    Map<String, dynamic> envelope,
  ) async {
    if (envelope['v'] != 1) return null;
    final nonceStr = envelope['nonce'] as String?;
    final cipherStr = envelope['cipherText'] as String?;
    final macStr = envelope['mac'] as String?;
    if (nonceStr == null || cipherStr == null || macStr == null) return null;

    final secretBox = SecretBox(
      base64Decode(cipherStr),
      nonce: base64Decode(nonceStr),
      mac: Mac(base64Decode(macStr)),
    );

    final clearBytes = await _aesGcm.decrypt(
      secretBox,
      secretKey: _masterKey!,
    );
    final decoded = jsonDecode(utf8.decode(clearBytes));
    if (decoded is! Map<String, dynamic>) return null;

    final rawEntries = decoded['entries'];
    final entries = <String, String>{};
    if (rawEntries is Map) {
      for (final entry in rawEntries.entries) {
        if (entry.key is String && entry.value != null) {
          entries[entry.key as String] = entry.value.toString();
        }
      }
    }

    return _VaultPlainPayload(
      schemaVersion: (decoded['schemaVersion'] as num?)?.toInt() ?? 1,
      appVersion: decoded['appVersion']?.toString() ?? _appVersion,
      entries: entries,
    );
  }

  Future<Map<String, dynamic>> _encryptPayload({
    required int schemaVersion,
    required String appVersion,
    required Map<String, String> entries,
    Map<String, dynamic>? extraEnvelopeFields,
  }) async {
    final plain = jsonEncode({
      'schemaVersion': schemaVersion,
      'appVersion': appVersion,
      'updatedAt': DateTime.now().toIso8601String(),
      'entries': entries,
    });

    final nonce = Uint8List(12);
    for (int i = 0; i < nonce.length; i++) {
      nonce[i] = _random.nextInt(256);
    }

    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plain),
      secretKey: _masterKey!,
      nonce: nonce,
    );

    return {
      'v': 1,
      if (extraEnvelopeFields != null) ...extraEnvelopeFields,
      'nonce': base64Encode(secretBox.nonce),
      'cipherText': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    };
  }

  Future<void> _persistCurrentStateLocked() async {
    final envelope = await _encryptPayload(
      schemaVersion: _schemaVersion,
      appVersion: _storedAppVersion.isNotEmpty ? _storedAppVersion : _appVersion,
      entries: _entries,
    );
    final encoded = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
    await _writePrimaryAtomically(encoded);
  }

  Future<void> _writePrimaryAtomically(Uint8List bytes) async {
    final primary = _file(_primaryFileName);
    final backup = _file(_backupFileName);
    final backupTemp = _file('$_backupFileName.tmp');
    final temp = _file(_tempFileName);

    // 1. Write new content to temp file and flush to disk.
    await temp.writeAsBytes(bytes, flush: true);

    // 2. Rotate existing primary to .bak atomically (so .bak always holds the last good file).
    if (await primary.exists()) {
      final existingBytes = await primary.readAsBytes();
      await backupTemp.writeAsBytes(existingBytes, flush: true);
      await _replaceFile(backupTemp, backup);
    }

    // 3. Move temp file into primary location.
    await _replaceFile(temp, primary);
  }

  Future<void> _replaceFile(File source, File target) async {
    try {
      await source.rename(target.path);
    } on FileSystemException {
      if (await target.exists()) {
        await target.delete();
      }
      await source.rename(target.path);
    }
  }

  String? readSync(String key) => _entries[key];

  Future<String?> read(String key) async {
    await init();
    return _entries[key];
  }

  Future<void> write(String key, String value) async {
    await init();
    await _synchronized(() async {
      if (_entries[key] == value && await _file(_primaryFileName).exists()) {
        return;
      }
      _entries[key] = value;
      await _persistCurrentStateLocked();
    });
  }

  /// Writes/deletes multiple keys in a single atomic disk write.
  /// Entries with a `null` value are deleted.
  Future<void> writeAll(
    Map<String, String?> updates, {
    int? schemaVersion,
    String? appVersion,
  }) async {
    await init();
    await _synchronized(() async {
      for (final entry in updates.entries) {
        if (entry.value == null) {
          _entries.remove(entry.key);
        } else {
          _entries[entry.key] = entry.value!;
        }
      }
      if (schemaVersion != null) _schemaVersion = schemaVersion;
      if (appVersion != null) _storedAppVersion = appVersion;
      await _persistCurrentStateLocked();
    });
  }

  Future<void> delete(String key) async {
    await init();
    await _synchronized(() async {
      if (!_entries.containsKey(key)) return;
      _entries.remove(key);
      await _persistCurrentStateLocked();
    });
  }

  Future<Map<String, String>> readAll({String? prefix}) async {
    await init();
    if (prefix == null || prefix.isEmpty) {
      return Map<String, String>.from(_entries);
    }
    return {
      for (final entry in _entries.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
  }

  Future<void> setMetadata({int? schemaVersion, String? appVersion}) async {
    await init();
    await _synchronized(() async {
      bool changed = false;
      if (schemaVersion != null && _schemaVersion != schemaVersion) {
        _schemaVersion = schemaVersion;
        changed = true;
      }
      if (appVersion != null && _storedAppVersion != appVersion) {
        _storedAppVersion = appVersion;
        changed = true;
      }
      if (changed || !await _file(_primaryFileName).exists()) {
        await _persistCurrentStateLocked();
      }
    });
  }

  /// Replaces all entries in the vault atomically (used by rollback/replace flows).
  Future<void> replaceAllEntries(
    Map<String, String> entries, {
    int? schemaVersion,
    String? appVersion,
  }) async {
    await init();
    await _synchronized(() async {
      _entries = Map<String, String>.from(entries);
      if (schemaVersion != null) _schemaVersion = schemaVersion;
      if (appVersion != null) _storedAppVersion = appVersion;
      await _persistCurrentStateLocked();
    });
  }

  /// Verifies that the primary file on disk can be read, decrypted, and parsed.
  Future<bool> verifyPrimaryOnDisk() async {
    await init();
    final primary = _file(_primaryFileName);
    if (!await primary.exists()) return false;
    final loaded = await _tryLoadFromFile(primary);
    return loaded != null;
  }

  /// Creates an encrypted full-vault snapshot and rotates older snapshots.
  Future<VaultSnapshotInfo> createSnapshot(String reason) async {
    await init();
    return _synchronized(() async {
      final safeReason = reason.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final now = DateTime.now();
      _snapshotCounter++;
      final id =
          'snapshot_${safeReason}_${now.microsecondsSinceEpoch}_$_snapshotCounter';
      final effectiveAppVersion =
          _storedAppVersion.isNotEmpty ? _storedAppVersion : _appVersion;

      final envelope = await _encryptPayload(
        schemaVersion: _schemaVersion,
        appVersion: effectiveAppVersion,
        entries: _entries,
        extraEnvelopeFields: {
          'id': id,
          'reason': safeReason,
          'createdAt': now.toIso8601String(),
          'schemaVersion': _schemaVersion,
          'appVersion': effectiveAppVersion,
          'entryCount': _entries.length,
        },
      );

      final snapFile = File(
        '${_snapshotsDir.path}${Platform.pathSeparator}$id.enc',
      );
      final snapTemp = File('${snapFile.path}.tmp');
      await snapTemp.writeAsBytes(
        utf8.encode(jsonEncode(envelope)),
        flush: true,
      );
      await _replaceFile(snapTemp, snapFile);

      await _rotateSnapshotsLocked();

      return VaultSnapshotInfo(
        id: id,
        reason: safeReason,
        createdAt: now,
        schemaVersion: _schemaVersion,
        appVersion: effectiveAppVersion,
        entryCount: _entries.length,
      );
    });
  }

  Future<List<File>> _listSnapshotFilesSorted() async {
    if (!await _snapshotsDir.exists()) return const [];
    final files = await _snapshotsDir
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.enc'))
        .cast<File>()
        .toList();

    final withStats = <(File, DateTime)>[];
    for (final file in files) {
      final stat = await file.stat();
      withStats.add((file, stat.modified));
    }
    withStats.sort((a, b) {
      final timeCmp = b.$2.compareTo(a.$2);
      if (timeCmp != 0) return timeCmp;
      return b.$1.path.compareTo(a.$1.path);
    });
    return withStats.map((e) => e.$1).toList();
  }

  Future<void> _rotateSnapshotsLocked() async {
    final files = await _listSnapshotFilesSorted();
    if (files.isEmpty) return;

    final preUpdate = <File>[];
    final preImport = <File>[];
    final other = <File>[];

    for (final f in files) {
      final name = f.uri.pathSegments.last;
      if (name.startsWith('snapshot_pre_update_')) {
        preUpdate.add(f);
      } else if (name.startsWith('snapshot_pre_import_')) {
        preImport.add(f);
      } else {
        other.add(f);
      }
    }

    final toDelete = <File>{};
    if (preUpdate.length > maxPreUpdateSnapshots) {
      toDelete.addAll(preUpdate.skip(maxPreUpdateSnapshots));
    }
    if (preImport.length > maxPreImportSnapshots) {
      toDelete.addAll(preImport.skip(maxPreImportSnapshots));
    }

    final kept = files.where((f) => !toDelete.contains(f)).toList();
    if (kept.length > maxTotalSnapshots) {
      toDelete.addAll(kept.skip(maxTotalSnapshots));
    }

    for (final file in toDelete) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Error deleting old snapshot ${file.path}: $e');
      }
    }
  }

  /// Lists available recovery snapshots, newest first.
  Future<List<VaultSnapshotInfo>> listSnapshots() async {
    await init();
    final files = await _listSnapshotFilesSorted();
    final infos = <VaultSnapshotInfo>[];

    for (final file in files) {
      try {
        final raw = await file.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final fileName = file.uri.pathSegments.last;
        final id = decoded['id']?.toString() ??
            fileName.replaceAll(RegExp(r'\.enc$'), '');
        final reason = decoded['reason']?.toString() ?? 'snapshot';
        final createdAt =
            DateTime.tryParse(decoded['createdAt']?.toString() ?? '') ??
                (await file.stat()).modified;
        final schemaVer = (decoded['schemaVersion'] as num?)?.toInt() ?? 1;
        final appVer = decoded['appVersion']?.toString() ?? '';
        final count = (decoded['entryCount'] as num?)?.toInt() ?? 0;

        infos.add(
          VaultSnapshotInfo(
            id: id,
            reason: reason,
            createdAt: createdAt,
            schemaVersion: schemaVer,
            appVersion: appVer,
            entryCount: count,
          ),
        );
      } catch (e) {
        debugPrint('Skipping unreadable snapshot ${file.path}: $e');
      }
    }

    infos.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return infos;
  }

  /// Validates and restores a snapshot by [snapshotId] into the live vault.
  Future<void> restoreSnapshot(String snapshotId) async {
    await init();
    await _synchronized(() async {
      final snapFile = File(
        '${_snapshotsDir.path}${Platform.pathSeparator}$snapshotId.enc',
      );
      if (!await snapFile.exists()) {
        throw StateError('Snapshot "$snapshotId" does not exist.');
      }

      final payload = await _tryLoadFromFile(snapFile);
      if (payload == null) {
        throw StateError('Snapshot "$snapshotId" is corrupted or unreadable.');
      }

      _applyPayload(payload);
      await _persistCurrentStateLocked();
    });
  }
}

class _VaultPlainPayload {
  final int schemaVersion;
  final String appVersion;
  final Map<String, String> entries;

  const _VaultPlainPayload({
    required this.schemaVersion,
    required this.appVersion,
    required this.entries,
  });
}
