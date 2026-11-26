import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skerdev_e621/models/app_backup_model.dart';
import 'package:skerdev_e621/models/board_model.dart';
import 'package:skerdev_e621/models/collection_model.dart';
import 'package:skerdev_e621/models/favorite_tags_model.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/pages/settings_page.dart';
import 'package:skerdev_e621/providers/auth_provider.dart';
import 'package:skerdev_e621/providers/blacklist_provider.dart';
import 'package:skerdev_e621/providers/boards_provider.dart';
import 'package:skerdev_e621/providers/favorite_tags_provider.dart';
import 'package:skerdev_e621/providers/follows_provider.dart';
import 'package:skerdev_e621/providers/ref_boards_provider.dart';
import 'package:skerdev_e621/services/backup_service.dart';
import 'package:skerdev_e621/services/local_data_vault.dart';
import 'package:skerdev_e621/services/storage_migration_service.dart';

class InMemorySecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return data[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      data[key] = value;
    } else {
      data.remove(key);
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map<String, String>.from(data);
  }
}

class MockBackupFileIo implements BackupFileIo {
  Uint8List? lastSavedBytes;
  String? lastSuggestedFileName;
  PickedBackupFile? nextPickedFile;
  bool cancelSave = false;

  @override
  Future<String?> saveBackupFile(
    Uint8List bytes,
    String suggestedFileName,
  ) async {
    if (cancelSave) return null;
    lastSavedBytes = bytes;
    lastSuggestedFileName = suggestedFileName;
    return '/mock/$suggestedFileName';
  }

  @override
  Future<PickedBackupFile?> pickBackupFile() async {
    return nextPickedFile;
  }
}

E621Post _makePost(int id, {String rating = 's'}) {
  return E621Post(
    id: id,
    previewUrl: 'https://static1.e621.net/preview/$id.jpg',
    fileUrl: 'https://static1.e621.net/file/$id.jpg',
    extension: 'jpg',
    artistTags: ['artist_$id'],
    characterTags: const [],
    speciesTags: const ['dragon'],
    copyrightTags: const [],
    generalTags: const ['solo'],
    rating: rating,
    score: id * 10,
    favCount: id * 5,
  );
}

E621Collection _makeCollection(CollectionType type, int id, int postCount) {
  return E621Collection(
    type: type,
    id: id,
    name: '${type.name}_$id',
    postCount: postCount,
  );
}

Future<
    ({
      Directory tempDir,
      InMemorySecureStorage secureStorage,
      LocalDataVault vault,
      AuthProvider auth,
      BlacklistProvider blacklist,
      BoardsProvider boards,
      RefBoardsProvider refBoards,
      FavoriteTagsProvider favTags,
      FollowsProvider follows,
    })> _createTestEnv({String appVersion = '1.0.0+1'}) async {
  final tempDir = await Directory.systemTemp.createTemp('sker_vault_test_');
  final secureStorage = InMemorySecureStorage();
  final vault = LocalDataVault(
    keyStorage: secureStorage,
    baseDirectory: tempDir,
    appVersion: appVersion,
  );
  await vault.init();
  await StorageMigrationService.migrateIfNeeded(
    vault: vault,
    legacyStorage: secureStorage,
    currentAppVersion: appVersion,
  );

  final auth = AuthProvider(storage: secureStorage, vault: vault);
  final blacklist = BlacklistProvider(storage: secureStorage, vault: vault);
  final boards = BoardsProvider(storage: secureStorage, vault: vault);
  final refBoards = RefBoardsProvider(storage: secureStorage, vault: vault);
  final favTags = FavoriteTagsProvider(storage: secureStorage, vault: vault);
  final follows = FollowsProvider(storage: secureStorage, vault: vault);

  await Future.wait([
    auth.tryAutoLogin(refreshInBackground: false),
    blacklist.loadSettings(),
    boards.loadBoards(),
    refBoards.loadRefBoards(),
    favTags.load(),
    follows.loadFollows(),
  ]);

  return (
    tempDir: tempDir,
    secureStorage: secureStorage,
    vault: vault,
    auth: auth,
    blacklist: blacklist,
    boards: boards,
    refBoards: refBoards,
    favTags: favTags,
    follows: follows,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalDataVault & Recovery Tests', () {
    test('encrypts data on disk and recovers from corrupted primary via .bak and snapshot', () async {
      final tempDir = await Directory.systemTemp.createTemp('vault_corrupt_');
      addTearDown(() => tempDir.delete(recursive: true));
      final keyStorage = InMemorySecureStorage();

      final vault = LocalDataVault(
        keyStorage: keyStorage,
        baseDirectory: tempDir,
      );
      await vault.init();
      await vault.write('secret_test_key', 'SUPER_SECRET_BOARD_DATA');
      await vault.createSnapshot('manual');
      await vault.write('second_key', 'SECOND_VALUE');

      final primaryFile = File('${tempDir.path}/vault_data.enc');
      final bakFile = File('${tempDir.path}/vault_data.enc.bak');
      expect(await primaryFile.exists(), isTrue);
      expect(await bakFile.exists(), isTrue);

      // Plaintext must NOT appear in raw encrypted file
      final rawDiskText = await primaryFile.readAsString();
      expect(rawDiskText, isNot(contains('SUPER_SECRET_BOARD_DATA')));
      expect(rawDiskText, isNot(contains('SECOND_VALUE')));

      // Corrupt primary file -> should recover from .bak automatically
      await primaryFile.writeAsString('{corrupted json!!!');
      final vaultFromBak = LocalDataVault(
        keyStorage: keyStorage,
        baseDirectory: tempDir,
      );
      await vaultFromBak.init();
      expect(vaultFromBak.recoveredFromBackup, isTrue);
      expect(vaultFromBak.lastRecoverySource, 'vault_data.enc.bak');
      expect(await vaultFromBak.read('secret_test_key'), 'SUPER_SECRET_BOARD_DATA');

      // Corrupt BOTH primary and .bak -> should recover from snapshot
      await primaryFile.writeAsString('bad_primary');
      await bakFile.writeAsString('bad_bak');
      final vaultFromSnap = LocalDataVault(
        keyStorage: keyStorage,
        baseDirectory: tempDir,
      );
      await vaultFromSnap.init();
      expect(vaultFromSnap.recoveredFromBackup, isTrue);
      expect(await vaultFromSnap.read('secret_test_key'), 'SUPER_SECRET_BOARD_DATA');
    });

    test('handles concurrent writes safely and rotates old snapshots', () async {
      final tempDir = await Directory.systemTemp.createTemp('vault_conc_');
      addTearDown(() => tempDir.delete(recursive: true));
      final keyStorage = InMemorySecureStorage();

      final vault = LocalDataVault(
        keyStorage: keyStorage,
        baseDirectory: tempDir,
      );
      await vault.init();

      await Future.wait([
        for (int i = 0; i < 12; i++) vault.write('k_$i', 'v_$i'),
      ]);

      final reloaded = LocalDataVault(
        keyStorage: keyStorage,
        baseDirectory: tempDir,
      );
      await reloaded.init();
      for (int i = 0; i < 12; i++) {
        expect(await reloaded.read('k_$i'), 'v_$i');
      }

      for (int i = 0; i < 5; i++) {
        await reloaded.createSnapshot('pre_update');
      }
      for (int i = 0; i < 4; i++) {
        await reloaded.createSnapshot('pre_import');
      }
      final snapshots = await reloaded.listSnapshots();
      expect(snapshots.length, lessThanOrEqualTo(LocalDataVault.maxTotalSnapshots));
    });
  });

  group('StorageMigrationService Tests', () {
    test('migrates v0 FlutterSecureStorage data to v1 vault while keeping credentials in secure storage', () async {
      final tempDir = await Directory.systemTemp.createTemp('vault_mig_');
      addTearDown(() => tempDir.delete(recursive: true));

      final legacy = InMemorySecureStorage();
      await legacy.write(key: 'username', value: 'SkerTester');
      await legacy.write(key: 'apiKey', value: 'SECRET_API_KEY_999');
      await legacy.write(key: 'site_host', value: 'e621.net');
      await legacy.write(key: 'is_over_18_verified', value: 'true');
      await legacy.write(key: 'blacklist_tags', value: 'gore\nscat');
      await legacy.write(
        key: 'boards_guest',
        value: jsonEncode([
          Board(
            id: 'b_guest',
            name: 'Guest Board',
            createdAt: DateTime(2026, 1, 1),
            postIds: [10],
            posts: [_makePost(10)],
          ).toJson(),
        ]),
      );
      await legacy.write(
        key: 'boards_user_SkerTester',
        value: jsonEncode([
          Board(
            id: 'b_user',
            name: 'User Board',
            createdAt: DateTime(2026, 1, 2),
            postIds: [20],
            posts: [_makePost(20)],
          ).toJson(),
        ]),
      );
      await legacy.write(
        key: 'follows_user_SkerTester',
        value: jsonEncode([
          FollowedCollection(
            collection: _makeCollection(CollectionType.pool, 42, 12),
            lastSeenCount: 10,
            followedAt: DateTime(2026, 1, 3),
          ).toJson(),
        ]),
      );
      await legacy.write(
        key: 'favorite_tags_local',
        value: jsonEncode({
          'version': 1,
          'tags': [
            FavoriteTag(
              name: 'dragon',
              category: 5,
              createdAt: DateTime(2026, 1, 4),
            ).toJson(),
          ],
          'sets': const [],
        }),
      );

      final vault = LocalDataVault(
        keyStorage: legacy,
        baseDirectory: tempDir,
        appVersion: '1.0.0+1',
      );
      final migRes = await StorageMigrationService.migrateIfNeeded(
        vault: vault,
        legacyStorage: legacy,
        currentAppVersion: '1.0.0+1',
      );

      expect(migRes.fromSchemaVersion, 0);
      expect(migRes.toSchemaVersion, 1);
      expect(migRes.migratedFromLegacy, isTrue);

      // Credentials MUST NOT be in vault
      expect(await vault.read('username'), isNull);
      expect(await vault.read('apiKey'), isNull);
      expect(await legacy.read(key: 'apiKey'), 'SECRET_API_KEY_999');

      // Migrated providers load everything cleanly from vault
      final boards = BoardsProvider(storage: legacy, vault: vault);
      await boards.loadBoards();
      expect(boards.boards.map((b) => b.id).toSet(), {'b_guest', 'b_user'});

      final follows = FollowsProvider(storage: legacy, vault: vault);
      await follows.updateForUser('SkerTester', isGuest: false);
      expect(follows.follows.length, 1);
      expect(follows.follows.first.newCount, 2);

      final favTags = FavoriteTagsProvider(storage: legacy, vault: vault);
      await favTags.load();
      expect(favTags.isFavorite('dragon'), isTrue);

      // Simulate app update to 1.1.0+2 -> should create automatic pre_update snapshot
      final vaultUpdated = LocalDataVault(
        keyStorage: legacy,
        baseDirectory: tempDir,
        appVersion: '1.1.0+2',
      );
      final updateRes = await StorageMigrationService.migrateIfNeeded(
        vault: vaultUpdated,
        legacyStorage: legacy,
        currentAppVersion: '1.1.0+2',
      );
      expect(updateRes.createdPreUpdateSnapshot, isTrue);
      final snaps = await vaultUpdated.listSnapshots();
      expect(snaps.any((s) => s.reason == 'pre_update'), isTrue);
    });
  });

  group('BackupService Export, Encryption & Import Tests', () {
    test('encrypted & unencrypted round-trip across all providers and rejects tampering/wrong password', () async {
      final env1 = await _createTestEnv();
      addTearDown(() => env1.tempDir.delete(recursive: true));

      await env1.auth.setSiteHost('e621.net', over18Confirmed: true);
      await env1.auth.setGuestMode(true);
      await env1.auth.toggleGuestFavorite(_makePost(100), false);
      await env1.blacklist.saveBlacklist('young\ncustom_rule');
      await env1.blacklist.setBlacklistPoolPosts(true);
      await env1.boards.createBoard('My Board', initialPost: _makePost(1));
      final rb = await env1.refBoards.createRefBoard(
        'Canvas 1',
        initialPosts: [_makePost(2)],
      );
      await env1.refBoards.toggleBoardLock(rb.id);
      await env1.favTags.createSet('Favs', initialTag: 'dragon', initialTagCategory: 5);
      await env1.follows.updateForUser(null, isGuest: true);
      await env1.follows.toggleFollow(_makeCollection(CollectionType.pool, 55, 8));

      final payload = await BackupService.collectBackupPayload(
        authProvider: env1.auth,
        blacklistProvider: env1.blacklist,
        boardsProvider: env1.boards,
        refBoardsProvider: env1.refBoards,
        favoriteTagsProvider: env1.favTags,
        followsProvider: env1.follows,
      );

      // 1. Encrypted export (low iterations in unit test for speed)
      final encryptedBytes = await BackupService.encodeBackup(
        payload,
        encrypt: true,
        password: 'my-strong-password',
        pbkdf2Iterations: 1000,
      );

      final header = BackupService.inspectBackupBytes(encryptedBytes);
      expect(header.encrypted, isTrue);
      expect(header.magic, BackupService.magic);

      // Wrong password fails
      await expectLater(
        () => BackupService.decodeBackupBytes(encryptedBytes, password: 'wrong'),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.type,
            'type',
            BackupFormatErrorType.wrongPasswordOrCorrupted,
          ),
        ),
      );

      // Tampered ciphertext fails
      final tamperedJson =
          jsonDecode(utf8.decode(encryptedBytes)) as Map<String, dynamic>;
      tamperedJson['checksum'] = '0' * 64;
      final tamperedBytes = Uint8List.fromList(utf8.encode(jsonEncode(tamperedJson)));
      await expectLater(
        () => BackupService.decodeBackupBytes(
          tamperedBytes,
          password: 'my-strong-password',
        ),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.type,
            'type',
            BackupFormatErrorType.checksumMismatch,
          ),
        ),
      );

      // Unsupported future version fails
      final futureJson =
          jsonDecode(utf8.decode(encryptedBytes)) as Map<String, dynamic>;
      futureJson['formatVersion'] = 999;
      expect(
        () => BackupService.inspectBackupBytes(
          Uint8List.fromList(utf8.encode(jsonEncode(futureJson))),
        ),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.type,
            'type',
            BackupFormatErrorType.unsupportedVersion,
          ),
        ),
      );

      // 2. Unencrypted export (Option A) works without credentials
      final plainBytes = await BackupService.encodeBackup(
        payload,
        encrypt: false,
      );
      expect(BackupService.inspectBackupBytes(plainBytes).encrypted, isFalse);

      // Credentials ALWAYS require encryption + password
      final payloadWithCreds = AppBackupPayload(
        schemaVersion: 1,
        appVersion: '1.0.0+1',
        exportedAt: DateTime.now(),
        credentials: const CredentialsBackupData(
          username: 'TestUser',
          apiKey: 'secret123',
        ),
      );
      await expectLater(
        () => BackupService.encodeBackup(payloadWithCreds, encrypt: false),
        throwsA(
          isA<BackupFormatException>().having(
            (e) => e.type,
            'type',
            BackupFormatErrorType.passwordRequiredForCredentials,
          ),
        ),
      );

      // Import encrypted backup into a brand-new environment
      final env2 = await _createTestEnv();
      addTearDown(() => env2.tempDir.delete(recursive: true));

      final decoded = await BackupService.decodeBackupBytes(
        encryptedBytes,
        password: 'my-strong-password',
      );
      await BackupService.applyBackup(
        payload: decoded,
        mode: BackupImportMode.replace,
        selection: const BackupCategorySelection(),
        vault: env2.vault,
        authProvider: env2.auth,
        blacklistProvider: env2.blacklist,
        boardsProvider: env2.boards,
        refBoardsProvider: env2.refBoards,
        favoriteTagsProvider: env2.favTags,
        followsProvider: env2.follows,
      );

      expect(env2.auth.host, 'e621.net');
      expect(env2.auth.isOver18Verified, isTrue);
      expect(env2.auth.isGuestMode, isTrue);
      expect((await env2.auth.getGuestFavorites()).map((p) => p.id), [100]);
      expect(env2.blacklist.blacklistPoolPosts, isTrue);
      expect(env2.blacklist.rawBlacklist, contains('custom_rule'));
      expect(env2.boards.boards.length, 1);
      expect(env2.boards.boards.first.name, 'My Board');
      expect(env2.refBoards.refBoards.length, 1);
      expect(env2.refBoards.refBoards.first.isLocked, isTrue);
      expect(env2.favTags.isFavorite('dragon'), isTrue);
      expect(env2.favTags.sets.length, 1);
      expect(env2.follows.follows.length, 1);
      expect(env2.follows.follows.first.collection.id, 55);
    });

    test('merge mode deduplicates cleanly without losing existing items', () async {
      final env = await _createTestEnv();
      addTearDown(() => env.tempDir.delete(recursive: true));

      final existingBoard = await env.boards.createBoard(
        'Local Board',
        initialPost: _makePost(1),
      );
      await env.favTags.addTag('existing_tag', category: 1);
      await env.blacklist.saveBlacklist('young\nexisting_rule');
      await env.follows.toggleFollow(_makeCollection(CollectionType.pool, 10, 5));

      final incomingPayload = AppBackupPayload(
        schemaVersion: 1,
        appVersion: '1.0.0+1',
        exportedAt: DateTime.now(),
        boards: [
          Board(
            id: existingBoard.id,
            name: 'Local Board',
            createdAt: existingBoard.createdAt,
            postIds: [1, 2],
            posts: [_makePost(1), _makePost(2)],
          ),
          Board(
            id: 'incoming_board_2',
            name: 'Imported Board',
            createdAt: DateTime(2026, 2, 1),
            postIds: [3],
            posts: [_makePost(3)],
          ),
        ],
        favoriteTags: [
          FavoriteTag(
            name: 'existing_tag',
            category: 1,
            createdAt: DateTime(2026, 1, 1),
          ),
          FavoriteTag(
            name: 'imported_tag',
            category: 4,
            createdAt: DateTime(2026, 1, 2),
          ),
        ],
        followsByNamespace: {
          'follows_guest': [
            FollowedCollection(
              collection: _makeCollection(CollectionType.pool, 10, 9),
              lastSeenCount: 7,
              followedAt: DateTime(2026, 1, 1),
            ),
            FollowedCollection(
              collection: _makeCollection(CollectionType.set, 20, 4),
              lastSeenCount: 4,
              followedAt: DateTime(2026, 1, 2),
            ),
          ],
        },
        blacklist: const BlacklistBackupData(
          rawTags: 'EXISTING_RULE\nnew_imported_rule',
          isEnabled: true,
          blacklistPoolPosts: false,
          hideBlacklistedPools: false,
          hideEmptyCollections: true,
        ),
      );

      await BackupService.applyBackup(
        payload: incomingPayload,
        mode: BackupImportMode.merge,
        selection: const BackupCategorySelection(
          guestFavorites: false,
          preferences: false,
          refBoards: false,
        ),
        vault: env.vault,
        authProvider: env.auth,
        blacklistProvider: env.blacklist,
        boardsProvider: env.boards,
        refBoardsProvider: env.refBoards,
        favoriteTagsProvider: env.favTags,
        followsProvider: env.follows,
      );

      expect(env.boards.boards.length, 2);
      expect(env.boards.getBoardById(existingBoard.id)?.postIds, [1, 2]);
      expect(env.favTags.totalTagCount, 2);
      expect(env.favTags.isFavorite('imported_tag'), isTrue);
      expect(env.follows.follows.length, 2);
      expect(
        env.follows.getFollow(CollectionType.pool, 10)?.lastSeenCount,
        7,
      );
      expect(env.blacklist.ruleCount, 3); // young, existing_rule, new_imported_rule
    });
  });

  group('SettingsPage Data & Backup Widget Tests', () {
    testWidgets('Option A export sheet defaults encryption ON, allows toggle OFF, and forces ON with credentials', (WidgetTester tester) async {
      final env = (await tester.runAsync(() async {
        final e = await _createTestEnv();
        await e.secureStorage.write(key: 'username', value: 'SkerUser');
        await e.secureStorage.write(key: 'apiKey', value: 'APIKEY123');
        await e.secureStorage.write(
          key: 'user_profile',
          value: jsonEncode({
            'id': 1,
            'name': 'SkerUser',
            'level_string': 'Member',
            'post_count': 0,
            'favorite_count': 0,
          }),
        );
        await e.auth.reloadFromStorage();
        await e.boards.createBoard('Exported Board', initialPost: _makePost(55));
        return e;
      }))!;
      addTearDown(() => tester.runAsync(() => env.tempDir.delete(recursive: true)));

      final mockIo = MockBackupFileIo();

      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<LocalDataVault?>.value(value: env.vault),
            ChangeNotifierProvider<AuthProvider>.value(value: env.auth),
            ChangeNotifierProvider<BlacklistProvider>.value(value: env.blacklist),
            ChangeNotifierProvider<BoardsProvider>.value(value: env.boards),
            ChangeNotifierProvider<RefBoardsProvider>.value(value: env.refBoards),
            ChangeNotifierProvider<FavoriteTagsProvider>.value(value: env.favTags),
            ChangeNotifierProvider<FollowsProvider>.value(value: env.follows),
          ],
          child: MaterialApp(
            home: SettingsPage(backupFileIo: mockIo),
          ),
        ),
      );

      expect(find.text('DATA & BACKUP'), findsOneWidget);
      expect(find.text('Export data'), findsOneWidget);
      expect(find.text('Import data'), findsOneWidget);
      expect(find.text('Recovery snapshots'), findsOneWidget);

      // Open Export Data sheet
      await tester.tap(find.text('Export data'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      expect(find.text('Export Data'), findsOneWidget);
      // Encryption ON by default -> password fields visible
      expect(find.text('Backup password'), findsOneWidget);
      expect(find.text('Confirm password'), findsOneWidget);

      // Toggle encryption OFF (Option A) -> password fields hide
      await tester.tap(find.text('Encrypt with password'));
      await tester.pumpAndSettle();
      expect(find.text('Backup password'), findsNothing);

      // Check "Include Account Credentials (API Key)" -> forces encryption back ON
      await tester.tap(find.text('Include Account Credentials (API Key)'));
      await tester.pumpAndSettle();
      expect(find.text('Backup password'), findsOneWidget);
      expect(find.text('Required when exporting API credentials'), findsOneWidget);

      // Uncheck credentials, toggle encryption OFF, and export unencrypted backup
      await tester.tap(find.text('Include Account Credentials (API Key)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Encrypt with password'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Export Backup'));
      await tester.pump();
      for (int i = 0; i < 60 && mockIo.lastSavedBytes == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(mockIo.lastSavedBytes, isNotNull);
      expect(mockIo.lastSuggestedFileName, endsWith('.skerbackup'));

      // Now import that exported backup into an empty environment via SettingsPage UI
      final envDest = (await tester.runAsync(() => _createTestEnv()))!;
      addTearDown(() => tester.runAsync(() => envDest.tempDir.delete(recursive: true)));
      final destIo = MockBackupFileIo()
        ..nextPickedFile = PickedBackupFile(
          name: mockIo.lastSuggestedFileName!,
          bytes: mockIo.lastSavedBytes!,
        );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<LocalDataVault?>.value(value: envDest.vault),
            ChangeNotifierProvider<AuthProvider>.value(value: envDest.auth),
            ChangeNotifierProvider<BlacklistProvider>.value(value: envDest.blacklist),
            ChangeNotifierProvider<BoardsProvider>.value(value: envDest.boards),
            ChangeNotifierProvider<RefBoardsProvider>.value(value: envDest.refBoards),
            ChangeNotifierProvider<FavoriteTagsProvider>.value(value: envDest.favTags),
            ChangeNotifierProvider<FollowsProvider>.value(value: envDest.follows),
          ],
          child: MaterialApp(
            home: SettingsPage(backupFileIo: destIo),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Import data'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      expect(find.text('Import Backup Preview'), findsOneWidget);
      expect(find.text('1 boards in backup'), findsOneWidget);

      await tester.tap(find.text('Import Data'));
      await tester.pump();
      for (int i = 0; i < 120 && find.text('Import Backup Preview').evaluate().isNotEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(envDest.boards.boards.length, 1);
      expect(envDest.boards.boards.first.name, 'Exported Board');
    });
  });
}
