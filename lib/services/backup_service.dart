import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/app_backup_model.dart';
import '../models/board_model.dart';
import '../models/collection_model.dart';
import '../models/favorite_tags_model.dart';
import '../models/post_model.dart';
import '../models/ref_board_model.dart';
import '../providers/auth_provider.dart';
import '../providers/blacklist_provider.dart';
import '../providers/boards_provider.dart';
import '../providers/favorite_tags_provider.dart';
import '../providers/follows_provider.dart';
import '../providers/ref_boards_provider.dart';
import 'local_data_vault.dart';

class PickedBackupFile {
  final String name;
  final Uint8List bytes;

  const PickedBackupFile({required this.name, required this.bytes});
}

/// Abstraction over OS file save/open dialogs so UI flows are unit-testable.
abstract class BackupFileIo {
  Future<String?> saveBackupFile(Uint8List bytes, String suggestedFileName);
  Future<PickedBackupFile?> pickBackupFile();
}

class PlatformBackupFileIo implements BackupFileIo {
  const PlatformBackupFileIo();

  @override
  Future<String?> saveBackupFile(
    Uint8List bytes,
    String suggestedFileName,
  ) async {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final outputPath = await FilePicker.saveFile(
      dialogTitle: 'Export Sker e621 Backup',
      fileName: suggestedFileName,
      type: isDesktop ? FileType.custom : FileType.any,
      allowedExtensions: isDesktop ? const ['skerbackup'] : null,
      bytes: bytes,
    );

    if (outputPath == null || outputPath.isEmpty) {
      return null;
    }

    if (isDesktop) {
      final finalPath = outputPath.toLowerCase().endsWith('.skerbackup')
          ? outputPath
          : '$outputPath.skerbackup';
      await File(finalPath).writeAsBytes(bytes, flush: true);
      return finalPath;
    }

    return outputPath;
  }

  @override
  Future<PickedBackupFile?> pickBackupFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Select .skerbackup file',
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return null;
    }

    final file = result.files.first;
    Uint8List? bytes = file.bytes;
    if ((bytes == null || bytes.isEmpty) && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) return null;

    return PickedBackupFile(name: file.name, bytes: bytes);
  }
}

/// Handles exporting, encrypting, verifying, decrypting, and importing
/// full local app backups (`.skerbackup`).
class BackupService {
  static const String magic = 'SKER_E621_BACKUP';
  static const int currentFormatVersion = 1;
  static const int defaultPbkdf2Iterations = 100000;
  static const int maxDecompressedBytes = 50 * 1024 * 1024;
  static const int maxEnvelopeBytes = 64 * 1024 * 1024;

  static final AesGcm _aesGcm = AesGcm.with256bits();
  static final Sha256 _sha256 = Sha256();
  static final Random _random = Random.secure();

  static String suggestedFileName([DateTime? now]) {
    final dt = now ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${dt.year}${two(dt.month)}${two(dt.day)}_${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
    return 'sker_e621_backup_$stamp.skerbackup';
  }

  /// Collects selected local data from all providers (and secure storage for
  /// optional credentials).
  static Future<AppBackupPayload> collectBackupPayload({
    required AuthProvider authProvider,
    required BlacklistProvider blacklistProvider,
    required BoardsProvider boardsProvider,
    required RefBoardsProvider refBoardsProvider,
    required FavoriteTagsProvider favoriteTagsProvider,
    required FollowsProvider followsProvider,
    BackupCategorySelection selection = const BackupCategorySelection(),
    String appVersion = LocalDataVault.currentAppVersion,
  }) async {
    final guestFavorites = selection.guestFavorites
        ? await authProvider.getGuestFavorites()
        : null;

    final followsByNamespace = selection.follows
        ? await followsProvider.readAllFollowNamespaces()
        : null;

    CredentialsBackupData? credentials;
    if (selection.credentials) {
      final creds = await authProvider.exportCredentials();
      final user = creds['username'];
      final key = creds['apiKey'];
      if (user != null && user.isNotEmpty && key != null && key.isNotEmpty) {
        credentials = CredentialsBackupData(
          username: user,
          apiKey: key,
          userProfileJson: creds['user_profile'],
        );
      }
    }

    return AppBackupPayload(
      schemaVersion: LocalDataVault.currentSchemaVersion,
      appVersion: appVersion,
      exportedAt: DateTime.now().toUtc(),
      boards: selection.boards ? List<Board>.from(boardsProvider.boards) : null,
      refBoards: selection.refBoards
          ? List<RefBoard>.from(refBoardsProvider.refBoards)
          : null,
      favoriteTags: selection.favoriteTags
          ? List<FavoriteTag>.from(favoriteTagsProvider.tags)
          : null,
      favoriteTagSets: selection.favoriteTags
          ? List<FavoriteTagSet>.from(favoriteTagsProvider.sets)
          : null,
      followsByNamespace: followsByNamespace,
      guestFavorites: guestFavorites,
      blacklist: selection.blacklist
          ? BlacklistBackupData(
              rawTags: blacklistProvider.rawBlacklist,
              isEnabled: blacklistProvider.isEnabled,
              blacklistPoolPosts: blacklistProvider.blacklistPoolPosts,
              hideBlacklistedPools: blacklistProvider.hideBlacklistedPools,
              hideEmptyCollections: blacklistProvider.hideEmptyCollections,
            )
          : null,
      preferences: selection.preferences
          ? PreferencesBackupData(
              siteHost: authProvider.host,
              isOver18Verified: authProvider.isOver18Verified,
              isGuestMode: authProvider.isGuestMode,
              artistModeEnabled: refBoardsProvider.artistModeEnabled,
            )
          : null,
      credentials: credentials,
    );
  }

  /// Encodes [payload] into `.skerbackup` bytes.
  ///
  /// When [encrypt] is true (default), compresses the JSON payload with gzip and
  /// encrypts it using AES-256-GCM with a key derived via PBKDF2-HMAC-SHA256.
  /// Credentials are never allowed in an unencrypted backup.
  static Future<Uint8List> encodeBackup(
    AppBackupPayload payload, {
    bool encrypt = true,
    String? password,
    int pbkdf2Iterations = defaultPbkdf2Iterations,
  }) async {
    if (payload.hasCredentials &&
        (!encrypt || password == null || password.isEmpty)) {
      throw const BackupFormatException(
        BackupFormatErrorType.passwordRequiredForCredentials,
        'A password is required whenever account credentials are included in a backup.',
      );
    }

    if (encrypt && (password == null || password.isEmpty)) {
      throw const BackupFormatException(
        BackupFormatErrorType.passwordRequired,
        'Enter a password to encrypt this backup.',
      );
    }

    final jsonBytes = utf8.encode(jsonEncode(payload.toJson()));
    final digest = await _sha256.hash(jsonBytes);
    final checksumHex = _bytesToHex(digest.bytes);
    final compressedBytes = gzip.encode(jsonBytes);

    final envelope = <String, dynamic>{
      'magic': magic,
      'formatVersion': currentFormatVersion,
      'schemaVersion': payload.schemaVersion,
      'appVersion': payload.appVersion,
      'exportedAt': payload.exportedAt.toIso8601String(),
      'encrypted': encrypt,
      'checksum': checksumHex,
    };

    if (encrypt) {
      final salt = _randomBytes(16);
      final nonce = _randomBytes(12);
      final key = await _deriveKey(
        password: password!,
        salt: salt,
        iterations: pbkdf2Iterations,
      );
      final secretBox = await _aesGcm.encrypt(
        compressedBytes,
        secretKey: key,
        nonce: nonce,
      );

      envelope['kdf'] = {
        'algorithm': 'PBKDF2-HMAC-SHA256',
        'iterations': pbkdf2Iterations,
        'salt': base64Encode(salt),
      };
      envelope['cipher'] = {
        'algorithm': 'AES-256-GCM',
        'nonce': base64Encode(secretBox.nonce),
        'mac': base64Encode(secretBox.mac.bytes),
      };
      envelope['payload'] = base64Encode(secretBox.cipherText);
    } else {
      envelope['payload'] = base64Encode(compressedBytes);
    }

    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  /// Parses and validates the unencrypted envelope header of [bytes] without
  /// decrypting the payload.
  static BackupEnvelopeHeader inspectBackupBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxEnvelopeBytes) {
      throw const BackupFormatException(
        BackupFormatErrorType.invalidFormat,
        'Backup file is empty or exceeds the maximum supported size.',
      );
    }

    Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Root JSON is not an object');
      }
      decoded = raw;
    } catch (_) {
      throw const BackupFormatException(
        BackupFormatErrorType.invalidFormat,
        'This file is not a valid Sker e621 backup.',
      );
    }

    final fileMagic = decoded['magic']?.toString();
    if (fileMagic != magic) {
      throw const BackupFormatException(
        BackupFormatErrorType.invalidFormat,
        'Unrecognized backup file format.',
      );
    }

    final formatVersion = (decoded['formatVersion'] as num?)?.toInt() ?? 0;
    final schemaVersion = (decoded['schemaVersion'] as num?)?.toInt() ?? 0;
    if (formatVersion <= 0 ||
        formatVersion > currentFormatVersion ||
        schemaVersion <= 0 ||
        schemaVersion > LocalDataVault.currentSchemaVersion) {
      throw const BackupFormatException(
        BackupFormatErrorType.unsupportedVersion,
        'This backup was created by a newer version of the app. Please update the app before importing it.',
      );
    }

    final encrypted = decoded['encrypted'] == true;
    final checksum = decoded['checksum']?.toString() ?? '';
    final payloadB64 = decoded['payload']?.toString() ?? '';
    if (checksum.isEmpty || payloadB64.isEmpty) {
      throw const BackupFormatException(
        BackupFormatErrorType.invalidFormat,
        'Backup file is missing payload or checksum data.',
      );
    }

    String? kdfAlgo;
    int? kdfIterations;
    String? kdfSalt;
    String? cipherAlgo;
    String? cipherNonce;
    String? cipherMac;

    if (encrypted) {
      final kdf = decoded['kdf'];
      final cipher = decoded['cipher'];
      if (kdf is! Map || cipher is! Map) {
        throw const BackupFormatException(
          BackupFormatErrorType.invalidFormat,
          'Encrypted backup is missing cipher metadata.',
        );
      }
      kdfAlgo = kdf['algorithm']?.toString();
      kdfIterations = (kdf['iterations'] as num?)?.toInt();
      kdfSalt = kdf['salt']?.toString();
      cipherAlgo = cipher['algorithm']?.toString();
      cipherNonce = cipher['nonce']?.toString();
      cipherMac = cipher['mac']?.toString();

      if (kdfIterations == null ||
          kdfIterations <= 0 ||
          kdfSalt == null ||
          cipherNonce == null ||
          cipherMac == null) {
        throw const BackupFormatException(
          BackupFormatErrorType.invalidFormat,
          'Encrypted backup header is incomplete.',
        );
      }
    }

    return BackupEnvelopeHeader(
      magic: fileMagic!,
      formatVersion: formatVersion,
      schemaVersion: schemaVersion,
      appVersion: decoded['appVersion']?.toString() ?? 'unknown',
      exportedAt: DateTime.tryParse(decoded['exportedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      encrypted: encrypted,
      kdfAlgorithm: kdfAlgo,
      kdfIterations: kdfIterations,
      kdfSaltBase64: kdfSalt,
      cipherAlgorithm: cipherAlgo,
      cipherNonceBase64: cipherNonce,
      cipherMacBase64: cipherMac,
      checksumSha256: checksum,
      payloadBase64: payloadB64,
    );
  }

  /// Decrypts (if encrypted), decompresses, verifies SHA-256 checksum, and
  /// parses a `.skerbackup` byte array into an [AppBackupPayload].
  static Future<AppBackupPayload> decodeBackupBytes(
    Uint8List bytes, {
    String? password,
  }) async {
    final header = inspectBackupBytes(bytes);

    List<int> compressedBytes;
    try {
      final payloadRaw = base64Decode(header.payloadBase64);

      if (header.encrypted) {
        if (password == null || password.isEmpty) {
          throw const BackupFormatException(
            BackupFormatErrorType.passwordRequired,
            'This backup is password-protected.',
          );
        }

        final salt = base64Decode(header.kdfSaltBase64!);
        final nonce = base64Decode(header.cipherNonceBase64!);
        final macBytes = base64Decode(header.cipherMacBase64!);

        final key = await _deriveKey(
          password: password,
          salt: salt,
          iterations: header.kdfIterations!,
        );

        try {
          compressedBytes = await _aesGcm.decrypt(
            SecretBox(payloadRaw, nonce: nonce, mac: Mac(macBytes)),
            secretKey: key,
          );
        } on SecretBoxAuthenticationError {
          throw const BackupFormatException(
            BackupFormatErrorType.wrongPasswordOrCorrupted,
            'Incorrect password or corrupted backup file.',
          );
        }
      } else {
        compressedBytes = payloadRaw;
      }
    } on BackupFormatException {
      rethrow;
    } catch (_) {
      throw const BackupFormatException(
        BackupFormatErrorType.wrongPasswordOrCorrupted,
        'Failed to decode backup payload.',
      );
    }

    final List<int> jsonBytes;
    try {
      jsonBytes = _decodeGzipWithLimit(compressedBytes, maxDecompressedBytes);
    } on BackupFormatException {
      rethrow;
    } catch (_) {
      throw const BackupFormatException(
        BackupFormatErrorType.wrongPasswordOrCorrupted,
        'Backup payload could not be decompressed.',
      );
    }

    final actualChecksum = _bytesToHex((await _sha256.hash(jsonBytes)).bytes);
    if (actualChecksum != header.checksumSha256.toLowerCase()) {
      throw const BackupFormatException(
        BackupFormatErrorType.checksumMismatch,
        'Backup integrity check failed (checksum mismatch).',
      );
    }

    try {
      final decoded = jsonDecode(utf8.decode(jsonBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Payload root is not an object');
      }
      return AppBackupPayload.fromJson(decoded);
    } catch (_) {
      throw const BackupFormatException(
        BackupFormatErrorType.invalidFormat,
        'Backup JSON data is malformed.',
      );
    }
  }

  /// Applies [payload] to the live vault/storage and reloads all providers in memory.
  ///
  /// Creates an automatic `pre_import` snapshot (when [vault] is provided) and
  /// rolls back atomically if any step fails.
  static Future<BackupImportSummary> applyBackup({
    required AppBackupPayload payload,
    required BackupImportMode mode,
    required BackupCategorySelection selection,
    LocalDataVault? vault,
    FlutterSecureStorage? storageFallback,
    required AuthProvider authProvider,
    required BlacklistProvider blacklistProvider,
    required BoardsProvider boardsProvider,
    required RefBoardsProvider refBoardsProvider,
    required FavoriteTagsProvider favoriteTagsProvider,
    required FollowsProvider followsProvider,
  }) async {
    VaultSnapshotInfo? snapshot;
    if (vault != null) {
      snapshot = await vault.createSnapshot('pre_import');
    }

    final fallbackStorage = storageFallback ?? const FlutterSecureStorage();
    final updates = <String, String?>{};

    int boardsCount = 0;
    int refBoardsCount = 0;
    int favTagsCount = 0;
    int favSetsCount = 0;
    int followsCount = 0;
    int guestFavsCount = 0;
    int blacklistCount = 0;
    bool prefsApplied = false;
    bool credsImported = false;

    try {
      // 1. Saved Boards
      if (selection.boards && payload.boards != null) {
        final result = mode == BackupImportMode.replace
            ? List<Board>.from(payload.boards!)
            : _mergeBoards(boardsProvider.boards, payload.boards!);
        result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        boardsCount = result.length;
        updates['boards_local'] = jsonEncode(
          result.map((b) => b.toJson()).toList(),
        );
      }

      // 2. Reference Canvases (Ref Boards)
      if (selection.refBoards && payload.refBoards != null) {
        final result = mode == BackupImportMode.replace
            ? List<RefBoard>.from(payload.refBoards!)
            : _mergeRefBoards(refBoardsProvider.refBoards, payload.refBoards!);
        result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        refBoardsCount = result.length;
        updates['ref_boards_local'] = jsonEncode(
          result.map((b) => b.toJson()).toList(),
        );
      }

      // 3. Favorite Tags & Tag Sets
      if (selection.favoriteTags && payload.hasFavoriteTagsSection) {
        final importedTags = payload.favoriteTags ?? const <FavoriteTag>[];
        final importedSets = payload.favoriteTagSets ?? const <FavoriteTagSet>[];

        final merged = mode == BackupImportMode.replace
            ? _normalizeTagsAndSets(importedTags, importedSets)
            : _mergeTagsAndSets(
                favoriteTagsProvider.tags,
                favoriteTagsProvider.sets,
                importedTags,
                importedSets,
              );

        favTagsCount = merged.$1.length;
        favSetsCount = merged.$2.length;
        updates[FavoriteTagsProvider.storageKey] = jsonEncode({
          'version': 1,
          'tags': merged.$1.map((t) => t.toJson()).toList(),
          'sets': merged.$2.map((s) => s.toJson()).toList(),
        });
      }

      // 4. Followed Pools & Sets (across all namespaces)
      if (selection.follows && payload.followsByNamespace != null) {
        final existingMap = await followsProvider.readAllFollowNamespaces();
        final importedMap = payload.followsByNamespace!;

        if (mode == BackupImportMode.replace) {
          for (final oldKey in existingMap.keys) {
            updates[oldKey] = null;
          }
          for (final entry in importedMap.entries) {
            followsCount += entry.value.length;
            updates[entry.key] = jsonEncode(
              entry.value.map((f) => f.toJson()).toList(),
            );
          }
        } else {
          final mergedMap = _mergeFollowNamespaces(existingMap, importedMap);
          for (final entry in mergedMap.entries) {
            followsCount += entry.value.length;
            updates[entry.key] = jsonEncode(
              entry.value.map((f) => f.toJson()).toList(),
            );
          }
        }
      }

      // 5. Guest Favorites
      if (selection.guestFavorites && payload.guestFavorites != null) {
        final existing = await authProvider.getGuestFavorites();
        final result = mode == BackupImportMode.replace
            ? List<E621Post>.from(payload.guestFavorites!)
            : _mergePostsById(existing, payload.guestFavorites!);
        guestFavsCount = result.length;
        updates['guest_favorites'] = jsonEncode(
          result.map((p) => p.toJson()).toList(),
        );
      }

      // 6. Blacklist & Filtering Settings
      if (selection.blacklist && payload.blacklist != null) {
        final bl = payload.blacklist!;
        if (mode == BackupImportMode.replace) {
          updates[BlacklistProvider.storageKeyTags] = bl.rawTags;
          updates[BlacklistProvider.storageKeyEnabled] =
              bl.isEnabled ? 'true' : 'false';
          updates[BlacklistProvider.storageKeyPoolPosts] =
              bl.blacklistPoolPosts ? 'true' : 'false';
          updates[BlacklistProvider.storageKeyHideBlacklistedPools] =
              bl.hideBlacklistedPools ? 'true' : 'false';
          updates[BlacklistProvider.storageKeyHideEmptyCollections] =
              bl.hideEmptyCollections ? 'true' : 'false';
          blacklistCount = bl.ruleCount;
        } else {
          final mergedBlacklist = _mergeBlacklistRaw(
            blacklistProvider.rawBlacklist,
            bl.rawTags,
          );
          updates[BlacklistProvider.storageKeyTags] = mergedBlacklist.$1;
          blacklistCount = mergedBlacklist.$2;
        }
      }

      // 7. Preferences (host / 18+ / guest mode)
      if (selection.preferences && payload.preferences != null) {
        final prefs = payload.preferences!;
        final normalizedHost = AuthProvider.normalizeHost(prefs.siteHost);
        final effectiveOver18 =
            prefs.isOver18Verified || (normalizedHost == 'e621.net' && prefs.isOver18Verified);
        final safeHost =
            (normalizedHost == 'e621.net' && !effectiveOver18)
                ? AuthProvider.defaultHost
                : normalizedHost;

        updates[AuthProvider.storageKeySiteHost] = safeHost;
        updates[AuthProvider.storageKeyOver18] =
            effectiveOver18 ? 'true' : 'false';
        if (prefs.artistModeEnabled != null) {
          updates[RefBoardsProvider.storageKeyArtistMode] =
              prefs.artistModeEnabled! ? 'true' : 'false';
        }

        if (mode == BackupImportMode.replace || !authProvider.isLoggedIn) {
          if (prefs.isGuestMode && !selection.credentials) {
            updates['is_guest_mode'] = 'true';
          } else if (mode == BackupImportMode.replace) {
            updates['is_guest_mode'] = null;
          }
        }
        prefsApplied = true;
      }

      // Write structured data atomically
      if (updates.isNotEmpty) {
        if (vault != null) {
          await vault.writeAll(updates);
        } else {
          for (final entry in updates.entries) {
            if (entry.value == null) {
              await fallbackStorage.delete(key: entry.key);
            } else {
              await fallbackStorage.write(key: entry.key, value: entry.value);
            }
          }
        }
      }

      // 8. Credentials (always stored in FlutterSecureStorage)
      if (selection.credentials && payload.hasCredentials) {
        final creds = payload.credentials!;
        await authProvider.importCredentials(
          username: creds.username,
          apiKey: creds.apiKey,
          userProfileJson: creds.userProfileJson,
        );
        credsImported = true;
      }

      // 9. Reload all providers immediately in memory
      await Future.wait([
        authProvider.reloadFromStorage(),
        blacklistProvider.loadSettings(),
        boardsProvider.reloadFromStorage(),
        refBoardsProvider.reloadFromStorage(),
        favoriteTagsProvider.reloadFromStorage(),
      ]);
      await followsProvider.updateForUser(
        authProvider.user?.name,
        isGuest: authProvider.isGuestMode,
      );
      await followsProvider.reloadFromStorage();

      return BackupImportSummary(
        mode: mode,
        boardsCount: boardsCount,
        refBoardsCount: refBoardsCount,
        favoriteTagsCount: favTagsCount,
        favoriteTagSetsCount: favSetsCount,
        followsCount: followsCount,
        guestFavoritesCount: guestFavsCount,
        blacklistRulesAddedOrApplied: blacklistCount,
        preferencesApplied: prefsApplied,
        credentialsImported: credsImported,
        preImportSnapshotId: snapshot?.id,
      );
    } catch (_) {
      if (vault != null && snapshot != null) {
        await vault.restoreSnapshot(snapshot.id);
        await Future.wait([
          authProvider.reloadFromStorage(),
          blacklistProvider.loadSettings(),
          boardsProvider.reloadFromStorage(),
          refBoardsProvider.reloadFromStorage(),
          favoriteTagsProvider.reloadFromStorage(),
          followsProvider.reloadFromStorage(),
        ]);
      }
      rethrow;
    }
  }

  // --- MERGE HELPERS ---

  static List<Board> _mergeBoards(List<Board> existing, List<Board> incoming) {
    final byId = <String, Board>{for (final b in existing) b.id: b};

    for (final inc in incoming) {
      final cur = byId[inc.id];
      if (cur == null) {
        byId[inc.id] = inc;
      } else {
        final mergedIds = List<int>.from(cur.postIds);
        final seenIds = mergedIds.toSet();
        for (final id in inc.postIds) {
          if (seenIds.add(id)) mergedIds.add(id);
        }

        final mergedPosts = List<E621Post>.from(cur.posts);
        final seenPostIds = mergedPosts.map((p) => p.id).toSet();
        for (final post in inc.posts) {
          if (seenPostIds.add(post.id)) mergedPosts.add(post);
        }

        byId[inc.id] = cur.copyWith(
          postIds: mergedIds,
          posts: mergedPosts,
        );
      }
    }

    return byId.values.toList();
  }

  static List<RefBoard> _mergeRefBoards(
    List<RefBoard> existing,
    List<RefBoard> incoming,
  ) {
    final byId = <String, RefBoard>{for (final b in existing) b.id: b};

    for (final inc in incoming) {
      final cur = byId[inc.id];
      if (cur == null) {
        byId[inc.id] = inc;
      } else {
        final primary =
            inc.updatedAt.isAfter(cur.updatedAt) ? inc : cur;
        final secondary = identical(primary, inc) ? cur : inc;

        final mergedItems = List<RefBoardItem>.from(primary.items);
        final seenItemIds = mergedItems.map((i) => i.id).toSet();
        for (final item in secondary.items) {
          if (seenItemIds.add(item.id)) {
            mergedItems.add(item);
          }
        }
        byId[inc.id] = primary.copyWith(items: mergedItems);
      }
    }

    return byId.values.toList();
  }

  static (List<FavoriteTag>, List<FavoriteTagSet>) _normalizeTagsAndSets(
    List<FavoriteTag> tags,
    List<FavoriteTagSet> sets,
  ) {
    final tagMap = <String, FavoriteTag>{};
    for (final tag in tags) {
      final norm = FavoriteTag.normalizeName(tag.name);
      if (norm.isEmpty) continue;
      final existing = tagMap[norm];
      if (existing == null || (existing.category == 0 && tag.category != 0)) {
        tagMap[norm] = tag.copyWith(name: norm);
      }
    }

    final setMap = <String, FavoriteTagSet>{};
    for (final set in sets) {
      if (set.id.isEmpty || set.name.trim().isEmpty) continue;
      for (final tName in set.tagNames) {
        final norm = FavoriteTag.normalizeName(tName);
        if (norm.isNotEmpty && !tagMap.containsKey(norm)) {
          tagMap[norm] = FavoriteTag(
            name: norm,
            category: FavoriteTag.inferCategory(norm),
            createdAt: set.createdAt,
          );
        }
      }
      setMap[set.id] = set;
    }

    return (tagMap.values.toList(), setMap.values.toList());
  }

  static (List<FavoriteTag>, List<FavoriteTagSet>) _mergeTagsAndSets(
    List<FavoriteTag> existingTags,
    List<FavoriteTagSet> existingSets,
    List<FavoriteTag> incomingTags,
    List<FavoriteTagSet> incomingSets,
  ) {
    final tagMap = <String, FavoriteTag>{};
    for (final t in existingTags) {
      final norm = FavoriteTag.normalizeName(t.name);
      if (norm.isNotEmpty) tagMap[norm] = t.copyWith(name: norm);
    }
    for (final t in incomingTags) {
      final norm = FavoriteTag.normalizeName(t.name);
      if (norm.isEmpty) continue;
      final cur = tagMap[norm];
      if (cur == null) {
        tagMap[norm] = t.copyWith(name: norm);
      } else if (cur.category == 0 && t.category != 0) {
        tagMap[norm] = cur.copyWith(category: t.category);
      }
    }

    final setMap = <String, FavoriteTagSet>{
      for (final s in existingSets) s.id: s,
    };
    for (final inc in incomingSets) {
      if (inc.id.isEmpty || inc.name.trim().isEmpty) continue;
      final cur = setMap[inc.id];
      if (cur == null) {
        setMap[inc.id] = inc;
      } else {
        final mergedTagNames = List<String>.from(cur.tagNames);
        final seen = mergedTagNames.toSet();
        for (final name in inc.tagNames) {
          final norm = FavoriteTag.normalizeName(name);
          if (norm.isNotEmpty && seen.add(norm)) {
            mergedTagNames.add(norm);
          }
        }
        setMap[inc.id] = cur.copyWith(tagNames: mergedTagNames);
      }
      for (final name in inc.tagNames) {
        final norm = FavoriteTag.normalizeName(name);
        if (norm.isNotEmpty && !tagMap.containsKey(norm)) {
          tagMap[norm] = FavoriteTag(
            name: norm,
            category: FavoriteTag.inferCategory(norm),
            createdAt: inc.createdAt,
          );
        }
      }
    }

    return (tagMap.values.toList(), setMap.values.toList());
  }

  static Map<String, List<FollowedCollection>> _mergeFollowNamespaces(
    Map<String, List<FollowedCollection>> existing,
    Map<String, List<FollowedCollection>> incoming,
  ) {
    final merged = <String, List<FollowedCollection>>{
      for (final e in existing.entries)
        e.key: List<FollowedCollection>.from(e.value),
    };

    for (final entry in incoming.entries) {
      final currentList = merged[entry.key] ?? <FollowedCollection>[];
      final byKey = <String, FollowedCollection>{
        for (final f in currentList) f.collection.key: f,
      };

      for (final inc in entry.value) {
        final cur = byKey[inc.collection.key];
        if (cur == null) {
          byKey[inc.collection.key] = inc;
        } else {
          final bestPostCount = max(
            cur.collection.postCount,
            inc.collection.postCount,
          );
          final bestLastSeen = max(cur.lastSeenCount, inc.lastSeenCount);
          final bestCover = cur.collection.coverUrl ?? inc.collection.coverUrl;
          byKey[inc.collection.key] = cur.copyWith(
            lastSeenCount: bestLastSeen,
            collection: cur.collection.copyWith(
              postCount: bestPostCount,
              coverUrl: bestCover,
            ),
          );
        }
      }

      merged[entry.key] = byKey.values.toList();
    }

    return merged;
  }

  static List<E621Post> _mergePostsById(
    List<E621Post> existing,
    List<E621Post> incoming,
  ) {
    final merged = List<E621Post>.from(existing);
    final seenIds = merged.map((p) => p.id).toSet();
    for (final post in incoming) {
      if (seenIds.add(post.id)) {
        merged.add(post);
      }
    }
    return merged;
  }

  static (String, int) _mergeBlacklistRaw(String existingRaw, String incomingRaw) {
    final lines = existingRaw.isEmpty ? <String>[] : existingRaw.split('\n');
    final seenRules = <String>{};
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        seenRules.add(trimmed.toLowerCase());
      }
    }

    int added = 0;
    for (final line in incomingRaw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (seenRules.add(trimmed.toLowerCase())) {
        lines.add(trimmed);
        added++;
      }
    }

    return (lines.join('\n').trim(), added);
  }

  // --- CRYPTO & COMPRESSION HELPERS ---

  static Future<SecretKey> _deriveKey({
    required String password,
    required List<int> salt,
    required int iterations,
  }) {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
  }

  static Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  static String _bytesToHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static List<int> _decodeGzipWithLimit(List<int> compressed, int maxBytes) {
    final output = <int>[];
    final sink = ByteConversionSink.withCallback((accumulated) {
      output.addAll(accumulated);
    });
    final cappedSink = _SizeCappedByteSink(sink, maxBytes);
    final converterSink = gzip.decoder.startChunkedConversion(cappedSink);
    converterSink.add(compressed);
    converterSink.close();
    return output;
  }
}

class _SizeCappedByteSink implements Sink<List<int>> {
  final Sink<List<int>> _inner;
  final int _maxBytes;
  int _total = 0;

  _SizeCappedByteSink(this._inner, this._maxBytes);

  @override
  void add(List<int> data) {
    _total += data.length;
    if (_total > _maxBytes) {
      throw const BackupFormatException(
        BackupFormatErrorType.payloadTooLarge,
        'Decompressed backup exceeds the maximum allowed size.',
      );
    }
    _inner.add(data);
  }

  @override
  void close() => _inner.close();
}
