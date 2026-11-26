import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skerdev_e621/models/favorite_tags_model.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/pages/details_page.dart';
import 'package:skerdev_e621/pages/settings_page.dart';
import 'package:skerdev_e621/providers/auth_provider.dart';
import 'package:skerdev_e621/providers/blacklist_provider.dart';
import 'package:skerdev_e621/providers/boards_provider.dart';
import 'package:skerdev_e621/providers/favorite_tags_provider.dart';
import 'package:skerdev_e621/providers/ref_boards_provider.dart';
import 'package:skerdev_e621/widgets/app_options_menu_button.dart';
import 'package:skerdev_e621/widgets/favorite_tags_sheet.dart';
import 'widget_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FavoriteTag & FavoriteTagSet Model Tests', () {
    test('normalizes names, infers filter categories, and serializes JSON', () {
      expect(FavoriteTag.normalizeName('  Dragon  '), 'dragon');
      expect(FavoriteTag.inferCategory('order:score'), -1);
      expect(FavoriteTag.inferCategory('-rating:e'), -1);
      expect(FavoriteTag.inferCategory('dragon'), 0);

      expect(FavoriteTag.labelForCategory(1), 'Artist');
      expect(FavoriteTag.labelForCategory(4), 'Character');
      expect(FavoriteTag.labelForCategory(3), 'Copyright');
      expect(FavoriteTag.labelForCategory(5), 'Species');
      expect(FavoriteTag.labelForCategory(-1), 'Filter');
      expect(FavoriteTag.labelForCategory(0), 'General');

      expect(FavoriteTag.colorForCategory(1), Colors.redAccent);
      expect(FavoriteTag.colorForCategory(5), Colors.amberAccent);
      expect(FavoriteTag.colorForCategory(-1), Colors.cyanAccent);

      final now = DateTime(2026, 1, 15, 10, 30);
      final tag = FavoriteTag(name: 'dragon', category: 5, createdAt: now);
      final restored = FavoriteTag.fromJson(tag.toJson());
      expect(restored.name, 'dragon');
      expect(restored.category, 5);
      expect(restored.createdAt, now);

      final set = FavoriteTagSet(
        id: 'set-1',
        name: 'Species',
        tagNames: const ['dragon', 'kobold'],
        createdAt: now,
      );
      final restoredSet = FavoriteTagSet.fromJson(set.toJson());
      expect(restoredSet.id, 'set-1');
      expect(restoredSet.name, 'Species');
      expect(restoredSet.tagNames, ['dragon', 'kobold']);
      expect(restoredSet.tagCount, 2);
    });
  });

  group('FavoriteTagsProvider Unit Tests', () {
    late FakeSecureStorage storage;
    late FavoriteTagsProvider provider;

    setUp(() {
      storage = FakeSecureStorage();
      provider = FavoriteTagsProvider(storage: storage);
    });

    test('adds, deduplicates, upgrades category, and toggles favorite tags', () async {
      expect(await provider.addTag('  Dragon ', category: 0), isTrue);
      expect(provider.totalTagCount, 1);
      expect(provider.isFavorite('DRAGON'), isTrue);
      expect(provider.getTag('dragon')?.category, 0);

      // Duplicate add returns false, but upgrades category from 0 -> 5
      expect(await provider.addTag('dragon', category: 5), isFalse);
      expect(provider.totalTagCount, 1);
      expect(provider.getTag('dragon')?.category, 5);

      // Toggle removes then re-adds
      expect(await provider.toggleFavoriteTag('dragon'), isFalse);
      expect(provider.isFavorite('dragon'), isFalse);
      expect(await provider.toggleFavoriteTag('dragon', category: 5), isTrue);
      expect(provider.isFavorite('dragon'), isTrue);
    });

    test('creates, renames, manages tags in sets, and persists across reload', () async {
      final speciesSet = await provider.createSet(
        'Species',
        initialTag: 'Dragon',
        initialTagCategory: 5,
      );
      final artistsSet = await provider.createSet('Artists');
      expect(speciesSet.id, isNot(artistsSet.id));
      expect(provider.isFavorite('dragon'), isTrue);
      expect(provider.isTagInSet(speciesSet.id, 'dragon'), isTrue);

      await provider.addTagToSet(speciesSet.id, 'kobold', category: 5);
      await provider.addTagToSet(artistsSet.id, 'artist_a', category: 1);
      expect(provider.buildQueryForSet(speciesSet.id), 'dragon kobold');

      await provider.renameSet(speciesSet.id, 'Fantasy Species');
      expect(provider.getSetById(speciesSet.id)?.name, 'Fantasy Species');

      // Reload from storage in fresh instance
      final reloaded = FavoriteTagsProvider(storage: storage);
      await reloaded.load();
      expect(reloaded.totalTagCount, 3);
      expect(reloaded.sets.length, 2);
      expect(reloaded.getSetById(speciesSet.id)?.name, 'Fantasy Species');
      expect(reloaded.buildQueryForSet(speciesSet.id), 'dragon kobold');

      // Removing a tag from a set keeps it in general favorites
      await reloaded.removeTagFromSet(speciesSet.id, 'kobold');
      expect(reloaded.isTagInSet(speciesSet.id, 'kobold'), isFalse);
      expect(reloaded.isFavorite('kobold'), isTrue);

      // Removing a tag globally removes it from all sets
      await reloaded.removeTag('dragon');
      expect(reloaded.isFavorite('dragon'), isFalse);
      expect(reloaded.isTagInSet(speciesSet.id, 'dragon'), isFalse);
    });

    test('deleteSet supports keeping or removing exclusive tags', () async {
      final s1 = await provider.createSet('Set One', initialTag: 'shared');
      final s2 = await provider.createSet('Set Two', initialTag: 'shared');
      await provider.addTagToSet(s1.id, 'only_one');

      await provider.deleteSet(s1.id, removeExclusiveTags: true);
      expect(provider.getSetById(s1.id), isNull);
      expect(provider.isFavorite('only_one'), isFalse);
      expect(provider.isFavorite('shared'), isTrue);

      await provider.deleteSet(s2.id, removeExclusiveTags: false);
      expect(provider.isFavorite('shared'), isTrue);
    });
  });

  group('BlacklistProvider Convenience Rule Methods', () {
    test('hasExactRule, addRule, and removeExactRule work case-insensitively', () async {
      final storage = FakeSecureStorage();
      final blacklist = BlacklistProvider(storage: storage);
      await blacklist.loadSettings();

      expect(blacklist.hasExactRule('SCAT'), isTrue);
      expect(await blacklist.addRule('scat'), isFalse);

      expect(await blacklist.addRule('gore'), isTrue);
      expect(blacklist.hasExactRule('Gore'), isTrue);

      expect(await blacklist.removeExactRule('GORE'), isTrue);
      expect(blacklist.hasExactRule('gore'), isFalse);
      expect(await blacklist.removeExactRule('nonexistent'), isFalse);
    });
  });

  group('Favorite Tags Widget Tests', () {
    testWidgets('AppOptionsMenuButton opens menu with Favorite Tags and Settings',
        (WidgetTester tester) async {
      final storage = FakeSecureStorage();
      final authProvider = AuthProvider(storage: storage);
      final blacklistProvider = BlacklistProvider(storage: storage);
      final favProvider = FavoriteTagsProvider(storage: storage);
      await favProvider.addTag('dragon', category: 5);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
            ChangeNotifierProvider<BlacklistProvider>.value(value: blacklistProvider),
            ChangeNotifierProvider<FavoriteTagsProvider>.value(value: favProvider),
          ],
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                actions: [
                  AppOptionsMenuButton(onSearchTags: (_) {}),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.menu), findsOneWidget);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();

      expect(find.text('Favorite Tags'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);

      // Tap Favorite Tags -> opens FavoriteTagsSheet
      await tester.tap(find.text('Favorite Tags'));
      await tester.pumpAndSettle();
      expect(find.text('dragon'), findsOneWidget);

      // Close sheet
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      // Open menu again and navigate to Settings
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('Long-pressing a tag on PostDetailPage opens SaveTagSheet and updates star/set/block',
        (WidgetTester tester) async {
      final storage = FakeSecureStorage();
      final authProvider = AuthProvider(storage: storage);
      final blacklistProvider = BlacklistProvider(storage: storage);
      await blacklistProvider.loadSettings();
      final boardsProvider = BoardsProvider(storage: storage);
      final refBoardsProvider = RefBoardsProvider(storage: storage);
      final favProvider = FavoriteTagsProvider(storage: storage);

      final post = E621Post(
        id: 4242,
        previewUrl: null,
        fileUrl: null,
        extension: 'jpg',
        artistTags: const ['cool_artist'],
        characterTags: const [],
        speciesTags: const ['eastern_dragon'],
        copyrightTags: const [],
        generalTags: const ['solo'],
        rating: 's',
        score: 42,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
            ChangeNotifierProvider<BlacklistProvider>.value(value: blacklistProvider),
            ChangeNotifierProvider<BoardsProvider>.value(value: boardsProvider),
            ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoardsProvider),
            ChangeNotifierProvider<FavoriteTagsProvider>.value(value: favProvider),
          ],
          child: MaterialApp(
            home: PostDetailPage(post: post),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.ensureVisible(find.text('eastern_dragon'));
      expect(find.text('eastern_dragon'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsNothing);

      // Long-press tag chip
      await tester.longPress(find.text('eastern_dragon'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Species'), findsWidgets);
      expect(find.text('Favorite Tags'), findsOneWidget);
      expect(find.text('Create new tag set'), findsOneWidget);

      // Save to Favorite Tags
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(favProvider.isFavorite('eastern_dragon'), isTrue);
      expect(favProvider.getTag('eastern_dragon')?.category, 5);

      // Create a new tag set from sheet
      await tester.tap(find.text('Create new tag set'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), 'Dragons');
      await tester.tap(find.text('Create & Add'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(favProvider.sets.length, 1);
      expect(favProvider.sets.first.name, 'Dragons');
      expect(favProvider.isTagInSet(favProvider.sets.first.id, 'eastern_dragon'), isTrue);

      // Block tag from sheet
      await tester.tap(find.text('Block'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(blacklistProvider.hasExactRule('eastern_dragon'), isTrue);
      expect(find.text('Blocked'), findsOneWidget);

      // Close sheet and confirm star indicator appears on PostDetailPage chip
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });

    testWidgets('FavoriteTagsSheet supports sets, Search All, single tap search, and multi-select combine',
        (WidgetTester tester) async {
      final storage = FakeSecureStorage();
      final favProvider = FavoriteTagsProvider(storage: storage);
      final set = await favProvider.createSet('Combos', initialTag: 'dragon', initialTagCategory: 5);
      await favProvider.addTagToSet(set.id, 'blue_scales', category: 0);
      await favProvider.addTag('solo', category: 0);

      final List<String> searchedQueries = [];

      await tester.pumpWidget(
        ChangeNotifierProvider<FavoriteTagsProvider>.value(
          value: favProvider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showFavoriteTagsSheet(
                      context,
                      onSearchTags: searchedQueries.add,
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // 1) Open sheet -> All shows 3 tags -> tap 'solo'
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('All (3)'), findsOneWidget);
      expect(find.text('Combos (2)'), findsOneWidget);

      await tester.tap(find.text('solo'));
      await tester.pumpAndSettle();
      expect(searchedQueries, ['solo']);

      // 2) Open sheet -> switch to 'Combos (2)' -> tap 'Search All'
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Combos (2)'));
      await tester.pumpAndSettle();
      expect(find.text('Search All'), findsOneWidget);

      await tester.tap(find.text('Search All'));
      await tester.pumpAndSettle();
      expect(searchedQueries.last, 'dragon blue_scales');

      // 3) Open sheet -> toggle Combine tags -> pick 'solo' and 'dragon' -> Search (2)
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Combine tags'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('solo'));
      await tester.tap(find.text('dragon'));
      await tester.pumpAndSettle();

      expect(find.text('Search (2)'), findsOneWidget);
      await tester.tap(find.text('Search (2)'));
      await tester.pumpAndSettle();
      expect(searchedQueries.last, 'solo dragon');
    });
  });
}
