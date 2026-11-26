import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skerdev_e621/models/app_backup_model.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/models/ref_board_model.dart';
import 'package:skerdev_e621/pages/account_page.dart';
import 'package:skerdev_e621/pages/board_detail_page.dart';
import 'package:skerdev_e621/pages/details_page.dart';
import 'package:skerdev_e621/pages/ref_canvas_page.dart';
import 'package:skerdev_e621/pages/settings_page.dart';
import 'package:skerdev_e621/pages/shared_board_preview_page.dart';
import 'package:skerdev_e621/providers/auth_provider.dart';
import 'package:skerdev_e621/providers/blacklist_provider.dart';
import 'package:skerdev_e621/providers/boards_provider.dart';
import 'package:skerdev_e621/providers/favorite_tags_provider.dart';
import 'package:skerdev_e621/providers/follows_provider.dart';
import 'package:skerdev_e621/providers/ref_boards_provider.dart';
import 'package:skerdev_e621/services/backup_service.dart';
import 'package:skerdev_e621/services/board_share_service.dart';
import 'package:skerdev_e621/services/local_data_vault.dart';
import 'package:skerdev_e621/services/storage_migration_service.dart';

class _InMemorySecureStorage extends Fake implements FlutterSecureStorage {
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

class _NoopBackupFileIo implements BackupFileIo {
  @override
  Future<PickedBackupFile?> pickBackupFile() async => null;

  @override
  Future<String?> saveBackupFile(
    bytes,
    String suggestedFileName,
  ) async =>
      null;
}

E621Post _makePost(int id) {
  return E621Post(
    id: id,
    previewUrl: null,
    fileUrl: null,
    extension: 'jpg',
    artistTags: ['artist_$id'],
    characterTags: const [],
    speciesTags: const ['dragon'],
    copyrightTags: const [],
    generalTags: const ['solo'],
    rating: 's',
    score: 10,
    favCount: 5,
  );
}

Future<
    ({
      Directory tempDir,
      _InMemorySecureStorage storage,
      LocalDataVault vault,
      AuthProvider auth,
      BlacklistProvider blacklist,
      BoardsProvider boards,
      RefBoardsProvider refBoards,
      FavoriteTagsProvider favTags,
      FollowsProvider follows,
    })> _createEnv() async {
  final tempDir = await Directory.systemTemp.createTemp('artist_mode_test_');
  final storage = _InMemorySecureStorage();
  final vault = LocalDataVault(keyStorage: storage, baseDirectory: tempDir);
  await vault.init();
  await StorageMigrationService.migrateIfNeeded(
    vault: vault,
    legacyStorage: storage,
  );

  final auth = AuthProvider(storage: storage, vault: vault);
  final blacklist = BlacklistProvider(storage: storage, vault: vault);
  final boards = BoardsProvider(storage: storage, vault: vault);
  final refBoards = RefBoardsProvider(storage: storage, vault: vault);
  final favTags = FavoriteTagsProvider(storage: storage, vault: vault);
  final follows = FollowsProvider(storage: storage, vault: vault);

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
    storage: storage,
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

  group('RefBoardsProvider Artist Mode persistence', () {
    test('defaults artistModeEnabled to false on fresh install with 0 ref boards',
        () async {
      final storage = _InMemorySecureStorage();
      final provider = RefBoardsProvider(storage: storage);

      await provider.loadRefBoards();

      expect(provider.refBoards, isEmpty);
      expect(provider.artistModeEnabled, isFalse);
      expect(storage.data[RefBoardsProvider.storageKeyArtistMode], isNull);
    });

    test('auto-enables artistModeEnabled when existing ref boards are present without preference key',
        () async {
      final storage = _InMemorySecureStorage();
      final existingBoard = RefBoard(
        id: 'existing_1',
        name: 'Anatomy Studies',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        items: const [],
      );
      storage.data['ref_boards_local'] = jsonEncode([existingBoard.toJson()]);

      final provider = RefBoardsProvider(storage: storage);
      await provider.loadRefBoards();

      expect(provider.refBoards.length, 1);
      expect(provider.artistModeEnabled, isTrue);
      expect(storage.data[RefBoardsProvider.storageKeyArtistMode], 'true');
    });

    test('toggling Artist Mode OFF preserves saved ref boards across reload',
        () async {
      final storage = _InMemorySecureStorage();
      final provider = RefBoardsProvider(storage: storage);
      await provider.loadRefBoards();
      await provider.setArtistModeEnabled(true);
      await provider.createRefBoard('My Study', initialPosts: [_makePost(42)]);

      await provider.setArtistModeEnabled(false);
      expect(provider.artistModeEnabled, isFalse);
      expect(provider.refBoards.length, 1);

      final reloaded = RefBoardsProvider(storage: storage);
      await reloaded.loadRefBoards();
      expect(reloaded.artistModeEnabled, isFalse);
      expect(reloaded.refBoards.length, 1);
      expect(reloaded.refBoards.first.name, 'My Study');
      expect(reloaded.refBoards.first.items.length, 1);
    });
  });

  group('Artist Mode UI gating', () {
    testWidgets(
        'SettingsPage shows Artist Mode toggle, updates Export subtitle, and offers UNDO when canvases exist',
        (WidgetTester tester) async {
      final storage = _InMemorySecureStorage();
      final auth = AuthProvider(storage: storage);
      final blacklist = BlacklistProvider(storage: storage);
      final refBoards = RefBoardsProvider(storage: storage);

      await tester.runAsync(() async {
        await auth.tryAutoLogin(refreshInBackground: false);
        await blacklist.loadSettings();
        await refBoards.loadRefBoards();
      });

      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<BlacklistProvider>.value(value: blacklist),
            ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoards),
          ],
          child: MaterialApp(
            home: SettingsPage(backupFileIo: _NoopBackupFileIo()),
          ),
        ),
      );

      expect(find.text('Artist Mode'), findsOneWidget);
      expect(
        find.text('Save boards, tags, follows, and settings'),
        findsOneWidget,
      );
      expect(refBoards.artistModeEnabled, isFalse);

      // Enable Artist Mode
      await tester.tap(find.text('Artist Mode'));
      await tester.pumpAndSettle();

      expect(refBoards.artistModeEnabled, isTrue);
      expect(
        find.text('Save boards, ref canvases, tags, follows, and settings'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Artist Mode enabled — Ref Canvas is now available in Account and Post pages.',
        ),
        findsOneWidget,
      );

      // Create a canvas and then disable Artist Mode
      await tester.runAsync(() => refBoards.createRefBoard('Pose Study'));
      await tester.pump();

      await tester.tap(find.text('Artist Mode'));
      await tester.pumpAndSettle();

      expect(refBoards.artistModeEnabled, isFalse);
      expect(
        find.text(
          'Artist Mode disabled. Your 1 ref canvas is safely kept.',
        ),
        findsOneWidget,
      );
      expect(find.text('UNDO'), findsOneWidget);

      await tester.tap(find.text('UNDO'));
      await tester.pumpAndSettle();
      expect(refBoards.artistModeEnabled, isTrue);
    });

    testWidgets(
        'AccountPage hides Ref Canvas tab and Saved Board menu action when OFF, and handles live toggling safely',
        (WidgetTester tester) async {
      final storage = _InMemorySecureStorage();
      final auth = AuthProvider(storage: storage);
      final boards = BoardsProvider(storage: storage);
      final refBoards = RefBoardsProvider(storage: storage);
      final favTags = FavoriteTagsProvider(storage: storage);

      await tester.runAsync(() async {
        await auth.setGuestMode(true);
        await boards.loadBoards();
        await boards.createBoard('Fav Dragons');
        await refBoards.loadRefBoards();
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<BoardsProvider>.value(value: boards),
            ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoards),
            ChangeNotifierProvider<FavoriteTagsProvider>.value(value: favTags),
          ],
          child: const MaterialApp(home: AccountPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Favorites'), findsOneWidget);
      expect(find.text('Saved Boards'), findsOneWidget);
      expect(find.text('Ref Canvas'), findsNothing);

      // Open Saved Boards tab and check card popup menu has no "Open in Ref Canvas"
      await tester.tap(find.text('Saved Boards'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      expect(find.text('Share Board'), findsOneWidget);
      expect(find.text('Open in Ref Canvas'), findsNothing);

      // Dismiss popup menu
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Enable Artist Mode live -> Ref Canvas tab appears and Saved Board action appears
      await refBoards.setArtistModeEnabled(true);
      await tester.pumpAndSettle();
      expect(find.text('Ref Canvas'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      expect(find.text('Open in Ref Canvas'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Switch to Ref Canvas tab, then disable Artist Mode live -> no TabController errors
      await tester.tap(find.text('Ref Canvas'));
      await tester.pumpAndSettle();
      await refBoards.setArtistModeEnabled(false);
      await tester.pumpAndSettle();

      expect(find.text('Ref Canvas'), findsNothing);
      expect(find.text('Saved Boards'), findsOneWidget);
    });

    testWidgets(
        'PostDetailPage hides Add to Ref Canvas button when Artist Mode is OFF and shows it when ON',
        (WidgetTester tester) async {
      final storage = _InMemorySecureStorage();
      final auth = AuthProvider(storage: storage);
      final boards = BoardsProvider(storage: storage);
      final refBoards = RefBoardsProvider(storage: storage);
      final post = _makePost(1234);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<BoardsProvider>.value(value: boards),
            ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoards),
          ],
          child: MaterialApp(home: PostDetailPage(post: post)),
        ),
      );

      expect(find.byTooltip('Add to Ref Canvas'), findsNothing);
      expect(find.byTooltip('Download Art'), findsOneWidget);
      expect(find.text('Save to Board'), findsOneWidget);

      await refBoards.setArtistModeEnabled(true);
      await tester.pump();
      expect(find.byTooltip('Add to Ref Canvas'), findsOneWidget);
    });

    testWidgets(
        'BoardDetailPage hides Open as Reference Canvas AppBar & menu actions when OFF and shows when ON',
        (WidgetTester tester) async {
      final storage = _InMemorySecureStorage();
      final auth = AuthProvider(storage: storage);
      final blacklist = BlacklistProvider(storage: storage);
      final boards = BoardsProvider(storage: storage);
      final refBoards = RefBoardsProvider(storage: storage);

      late final String boardId;
      await tester.runAsync(() async {
        await blacklist.loadSettings();
        await boards.loadBoards();
        final board = await boards.createBoard('Sample Board');
        boardId = board.id;
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<BlacklistProvider>.value(value: blacklist),
            ChangeNotifierProvider<BoardsProvider>.value(value: boards),
            ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoards),
          ],
          child: MaterialApp(home: BoardDetailPage(boardId: boardId)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Open as Reference Canvas'), findsNothing);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Open as Ref Canvas'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await refBoards.setArtistModeEnabled(true);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Open as Reference Canvas'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Open as Ref Canvas'), findsOneWidget);
    });

    testWidgets(
        'SharedBoardPreviewPage uses Grid view & progressive disclosure when Artist Mode is OFF and enables on opt-in',
        (WidgetTester tester) async {
      final storage = _InMemorySecureStorage();
      final auth = AuthProvider(storage: storage);
      final blacklist = BlacklistProvider(storage: storage);
      final boards = BoardsProvider(storage: storage);
      final refBoards = RefBoardsProvider(storage: storage);

      const payload = SharedBoardPayload(
        type: SharedPayloadType.refCanvas,
        name: 'Shared Anatomy',
        author: 'FriendArtist',
        refItems: [
          SharedRefItemData(
            x: 50,
            y: 50,
            width: 280,
            height: 380,
            fallbackImageUrl: 'https://example.com/a.png',
          ),
        ],
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<BlacklistProvider>.value(value: blacklist),
            ChangeNotifierProvider<BoardsProvider>.value(value: boards),
            ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoards),
          ],
          child: const MaterialApp(
            home: SharedBoardPreviewPage(payload: payload),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Opens in Grid View (tooltip offers switching to 2D Canvas View)
      expect(find.byTooltip('Switch to 2D Canvas View'), findsOneWidget);
      expect(find.text('Save as Board'), findsOneWidget);
      expect(find.text('Enable Artist Mode & Save'), findsOneWidget);

      await tester.tap(find.text('Enable Artist Mode & Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(refBoards.artistModeEnabled, isTrue);
      expect(refBoards.refBoards.length, 1);
      expect(refBoards.refBoards.first.name, 'Shared Anatomy');
      expect(find.byType(RefCanvasPage), findsOneWidget);
    });
  });

  group('Artist Mode Backup & Export UI', () {
    test('BackupService preserves artistModeEnabled inside PreferencesBackupData',
        () async {
      final src = await _createEnv();
      final dest = await _createEnv();
      addTearDown(() => src.tempDir.delete(recursive: true));
      addTearDown(() => dest.tempDir.delete(recursive: true));

      await src.refBoards.setArtistModeEnabled(true);

      final payload = await BackupService.collectBackupPayload(
        authProvider: src.auth,
        blacklistProvider: src.blacklist,
        boardsProvider: src.boards,
        refBoardsProvider: src.refBoards,
        favoriteTagsProvider: src.favTags,
        followsProvider: src.follows,
      );
      expect(payload.preferences?.artistModeEnabled, isTrue);

      final bytes = await BackupService.encodeBackup(
        payload,
        encrypt: false,
      );
      final decoded = await BackupService.decodeBackupBytes(bytes);
      expect(decoded.preferences?.artistModeEnabled, isTrue);

      await BackupService.applyBackup(
        payload: decoded,
        mode: BackupImportMode.replace,
        selection: const BackupCategorySelection(),
        vault: dest.vault,
        authProvider: dest.auth,
        blacklistProvider: dest.blacklist,
        boardsProvider: dest.boards,
        refBoardsProvider: dest.refBoards,
        favoriteTagsProvider: dest.favTags,
        followsProvider: dest.follows,
      );

      expect(dest.refBoards.artistModeEnabled, isTrue);
    });

    testWidgets(
        'Export sheet hides Reference Canvases when Artist Mode OFF and 0 canvases, but shows when hidden canvases exist',
        (WidgetTester tester) async {
      final env = (await tester.runAsync(_createEnv))!;
      addTearDown(() => tester.runAsync(() => env.tempDir.delete(recursive: true)));

      tester.view.physicalSize = const Size(800, 2000);
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
            home: SettingsPage(backupFileIo: _NoopBackupFileIo()),
          ),
        ),
      );

      // Case 1: Artist Mode OFF, 0 canvases -> row hidden
      await tester.tap(find.text('Export data'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('Reference Canvases'), findsNothing);

      // Close sheet
      Navigator.of(tester.element(find.text('Export Data'))).pop();
      await tester.pumpAndSettle();

      // Case 2: Artist Mode OFF, 1 hidden canvas -> row shown with hint
      await tester.runAsync(() => env.refBoards.createRefBoard('Hidden Study'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Export data'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('Reference Canvases'), findsOneWidget);
      expect(
        find.text('1 canvases (hidden while Artist Mode is off)'),
        findsOneWidget,
      );
    });
  });
}
