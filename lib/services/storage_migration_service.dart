import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/board_model.dart';
import '../models/ref_board_model.dart';
import 'local_data_vault.dart';

class MigrationResult {
  final int fromSchemaVersion;
  final int toSchemaVersion;
  final bool migratedFromLegacy;
  final bool createdPreUpdateSnapshot;
  final int migratedKeyCount;

  const MigrationResult({
    required this.fromSchemaVersion,
    required this.toSchemaVersion,
    this.migratedFromLegacy = false,
    this.createdPreUpdateSnapshot = false,
    this.migratedKeyCount = 0,
  });
}

/// Handles one-time `v0 -> v1` migration from legacy [FlutterSecureStorage]
/// keys into [LocalDataVault], as well as pre-update snapshot creation and
/// versioned schema migrations across future app updates.
class StorageMigrationService {
  static const List<String> _directLegacyKeys = [
    'site_host',
    'is_over_18_verified',
    'is_guest_mode',
    'guest_favorites',
    'blacklist_tags',
    'blacklist_enabled',
    'blacklist_pool_posts',
    'blacklist_hide_pools',
    'blacklist_hide_empty_collections',
    'favorite_tags_local',
    'follows_guest',
    'artist_mode_enabled',
  ];

  /// Ensures [vault] is initialized and migrated to [LocalDataVault.currentSchemaVersion].
  ///
  /// Sensitive credentials (`username`, `apiKey`, `user_profile`) remain solely
  /// in [legacyStorage] (`FlutterSecureStorage`) and are never moved to disk.
  static Future<MigrationResult> migrateIfNeeded({
    required LocalDataVault vault,
    required FlutterSecureStorage legacyStorage,
    String currentAppVersion = LocalDataVault.currentAppVersion,
  }) async {
    await vault.init();

    final startSchema = vault.schemaVersion;

    // Case 1: Fresh vault (v0) -> migrate structured keys from legacy FlutterSecureStorage.
    if (startSchema == 0) {
      final collected = await _collectLegacyEntries(legacyStorage);
      await vault.writeAll(
        collected,
        schemaVersion: LocalDataVault.currentSchemaVersion,
        appVersion: currentAppVersion,
      );

      final verified = await vault.verifyPrimaryOnDisk();
      if (!verified) {
        throw StateError('Vault disk verification failed after legacy migration.');
      }

      return MigrationResult(
        fromSchemaVersion: 0,
        toSchemaVersion: LocalDataVault.currentSchemaVersion,
        migratedFromLegacy: collected.isNotEmpty,
        migratedKeyCount: collected.length,
      );
    }

    // Case 2: Existing vault on an older schema or different app version.
    final needsSchemaUpgrade = startSchema < LocalDataVault.currentSchemaVersion;
    final needsAppVersionUpdate =
        vault.storedAppVersion.isNotEmpty && vault.storedAppVersion != currentAppVersion;

    if (!needsSchemaUpgrade && !needsAppVersionUpdate) {
      return MigrationResult(
        fromSchemaVersion: startSchema,
        toSchemaVersion: startSchema,
      );
    }

    VaultSnapshotInfo? snapshot;
    if (vault.entryCount > 0) {
      snapshot = await vault.createSnapshot('pre_update');
    }

    try {
      int workingSchema = startSchema;
      while (workingSchema < LocalDataVault.currentSchemaVersion) {
        // Placeholder for future sequential schema steps (e.g. v1 -> v2).
        workingSchema++;
      }

      await vault.setMetadata(
        schemaVersion: workingSchema,
        appVersion: currentAppVersion,
      );

      return MigrationResult(
        fromSchemaVersion: startSchema,
        toSchemaVersion: workingSchema,
        createdPreUpdateSnapshot: snapshot != null,
      );
    } catch (e) {
      debugPrint('Schema migration failed ($e); rolling back to snapshot.');
      if (snapshot != null) {
        await vault.restoreSnapshot(snapshot.id);
      }
      rethrow;
    }
  }

  static Future<Map<String, String>> _collectLegacyEntries(
    FlutterSecureStorage legacyStorage,
  ) async {
    final entries = <String, String>{};

    // 1. Attempt readAll() on real FlutterSecureStorage to catch all user-namespaced keys.
    Map<String, String> allLegacy = {};
    try {
      allLegacy = await legacyStorage.readAll();
    } catch (_) {
      // FakeSecureStorage in unit tests may not implement readAll().
    }

    Future<String?> readLegacyKey(String key) async {
      if (allLegacy.containsKey(key)) return allLegacy[key];
      try {
        return await legacyStorage.read(key: key);
      } catch (_) {
        return null;
      }
    }

    for (final key in _directLegacyKeys) {
      final val = await readLegacyKey(key);
      if (val != null && val.isNotEmpty) {
        entries[key] = val;
      }
    }

    // Check active username in case readAll() wasn't available.
    final activeUsername = await readLegacyKey('username');

    // Collect follows_user_* keys
    final followUserKeys = <String>{
      for (final k in allLegacy.keys)
        if (k.startsWith('follows_user_')) k,
      if (activeUsername != null && activeUsername.isNotEmpty)
        'follows_user_$activeUsername',
    };
    for (final key in followUserKeys) {
      final val = await readLegacyKey(key);
      if (val != null && val.isNotEmpty) {
        entries[key] = val;
      }
    }

    // Merge boards_local + boards_guest + boards_user_* into boards_local
    final boardKeys = <String>{
      'boards_local',
      'boards_guest',
      for (final k in allLegacy.keys)
        if (k.startsWith('boards_user_')) k,
      if (activeUsername != null && activeUsername.isNotEmpty)
        'boards_user_$activeUsername',
    };
    final mergedBoards = <Board>[];
    final seenBoardIds = <String>{};
    for (final key in boardKeys) {
      final raw = await readLegacyKey(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded.whereType<Map<String, dynamic>>()) {
            final board = Board.fromJson(item);
            if (seenBoardIds.add(board.id)) {
              mergedBoards.add(board);
            }
          }
        }
      } catch (e) {
        debugPrint('Skipping unreadable legacy boards key "$key": $e');
      }
    }
    if (mergedBoards.isNotEmpty) {
      mergedBoards.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      entries['boards_local'] = jsonEncode(
        mergedBoards.map((b) => b.toJson()).toList(),
      );
    }

    // Merge ref_boards_local + ref_boards_guest + ref_boards_user_* into ref_boards_local
    final refBoardKeys = <String>{
      'ref_boards_local',
      'ref_boards_guest',
      for (final k in allLegacy.keys)
        if (k.startsWith('ref_boards_user_')) k,
      if (activeUsername != null && activeUsername.isNotEmpty)
        'ref_boards_user_$activeUsername',
    };
    final mergedRefBoards = <RefBoard>[];
    final seenRefBoardIds = <String>{};
    for (final key in refBoardKeys) {
      final raw = await readLegacyKey(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded.whereType<Map<String, dynamic>>()) {
            final board = RefBoard.fromJson(item);
            if (seenRefBoardIds.add(board.id)) {
              mergedRefBoards.add(board);
            }
          }
        }
      } catch (e) {
        debugPrint('Skipping unreadable legacy ref boards key "$key": $e');
      }
    }
    if (mergedRefBoards.isNotEmpty) {
      mergedRefBoards.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      entries['ref_boards_local'] = jsonEncode(
        mergedRefBoards.map((b) => b.toJson()).toList(),
      );
    }

    return entries;
  }
}
