import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:skerdev_e621/models/collection_filters.dart';
import 'package:skerdev_e621/models/collection_model.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/pages/collections_page.dart';
import 'package:skerdev_e621/providers/auth_provider.dart';
import 'package:skerdev_e621/providers/blacklist_provider.dart';
import 'package:skerdev_e621/providers/follows_provider.dart';
import 'package:skerdev_e621/services/e621_collections_api.dart';
import 'package:skerdev_e621/widgets/collection_card.dart';
import 'widget_test.dart';

E621Post _buildPost({
  required int id,
  int favCount = 0,
  List<String> general = const [],
  List<String> species = const [],
  String description = '',
  List<int> poolIds = const [],
}) {
  return E621Post(
    id: id,
    previewUrl: 'https://example.com/thumb_$id.jpg',
    fileUrl: 'https://example.com/file_$id.jpg',
    extension: 'jpg',
    artistTags: const [],
    characterTags: const [],
    speciesTags: species,
    copyrightTags: const [],
    generalTags: general,
    favCount: favCount,
    rating: 's',
    description: description,
    poolIds: poolIds,
  );
}

void main() {
  group('Pools & Sets FavCount Sum and Keyword Filtering Tests', () {
    test('calculates totalFavCount and sorts pools by highest summed favCount', () {
      final poolLow = E621Collection(
        type: CollectionType.pool,
        id: 1,
        name: 'Low_Fav_Pool',
        postCount: 2,
        postIds: const [10, 11],
        posts: [
          _buildPost(id: 10, favCount: 15),
          _buildPost(id: 11, favCount: 25),
        ],
      );

      final poolHigh = E621Collection(
        type: CollectionType.pool,
        id: 2,
        name: 'High_Fav_Pool',
        postCount: 3,
        postIds: const [20, 21, 22],
        posts: [
          _buildPost(id: 20, favCount: 400),
          _buildPost(id: 21, favCount: 350),
          _buildPost(id: 22, favCount: 500),
        ],
      );

      final poolMid = E621Collection(
        type: CollectionType.pool,
        id: 3,
        name: 'Mid_Fav_Pool',
        postCount: 2,
        postIds: const [30, 31],
        posts: [
          _buildPost(id: 30, favCount: 120),
          _buildPost(id: 31, favCount: 80),
        ],
      );

      expect(poolLow.totalFavCount, 40);
      expect(poolMid.totalFavCount, 200);
      expect(poolHigh.totalFavCount, 1250);
      expect(poolHigh.formattedTotalFavCount, '1.3k');

      final sorted = E621CollectionsApi.sortPools(
        [poolLow, poolHigh, poolMid],
        order: 'fav_count',
      );

      expect(sorted.map((p) => p.id).toList(), [2, 3, 1]);
    });

    test('counts posts matching keyword and sorts pools by most keyword posts', () {
      final poolFewMatches = E621Collection(
        type: CollectionType.pool,
        id: 10,
        name: 'Adventure_Series',
        postCount: 3,
        posts: [
          _buildPost(id: 101, species: ['dragon'], general: ['forest'], favCount: 50),
          _buildPost(id: 102, species: ['wolf'], general: ['forest'], favCount: 50),
          _buildPost(id: 103, species: ['fox'], general: ['city'], favCount: 50),
        ],
      );

      final poolManyMatches = E621Collection(
        type: CollectionType.pool,
        id: 20,
        name: 'Chronicles_Comic',
        postCount: 4,
        posts: [
          _buildPost(id: 201, species: ['dragon'], general: ['fire'], favCount: 20),
          _buildPost(id: 202, species: ['dragon'], general: ['wings'], favCount: 30),
          _buildPost(id: 203, species: ['kobold'], description: 'A mighty dragon appears', favCount: 40),
          _buildPost(id: 204, species: ['wolf'], general: ['snow'], favCount: 10),
        ],
      );

      final poolNoMatches = E621Collection(
        type: CollectionType.pool,
        id: 30,
        name: 'Space_Cats',
        postCount: 2,
        posts: [
          _buildPost(id: 301, species: ['feline'], general: ['scifi']),
          _buildPost(id: 302, species: ['feline'], general: ['spaceship']),
        ],
      );

      expect(poolFewMatches.keywordMatchCount('dragon'), 1);
      expect(poolManyMatches.keywordMatchCount('dragon'), 3);
      expect(poolNoMatches.keywordMatchCount('dragon'), 0);

      expect(poolFewMatches.matchesKeyword('dragon'), isTrue);
      expect(poolManyMatches.matchesKeyword('dragon'), isTrue);
      expect(poolNoMatches.matchesKeyword('dragon'), isFalse);

      final filtered = [poolFewMatches, poolManyMatches, poolNoMatches]
          .where((p) => p.matchesKeyword('dragon'))
          .toList();
      expect(filtered, hasLength(2));

      final sorted = E621CollectionsApi.sortPools(
        filtered,
        order: 'keyword_posts',
        query: 'dragon',
        keywordSearch: true,
      );
      expect(sorted.map((p) => p.id).toList(), [20, 10]);
    });

    test('searchPools with keywordSearch discovers pools via post tags and sorts by keyword_posts', () async {
      final mockClient = MockClient((request) async {
        final path = request.url.path;
        final params = request.url.queryParameters;

        if (path == '/pools.json') {
          if (params['search[id]'] != null) {
            return http.Response(
              jsonEncode([
                {
                  'id': 500,
                  'name': 'Hidden_Gem_Series',
                  'description': 'A long story',
                  'category': 'series',
                  'post_count': 2,
                  'post_ids': [5001, 5002],
                },
              ]),
              200,
            );
          }
          if (params['search[name_matches]'] != null) {
            return http.Response(
              jsonEncode([
                {
                  'id': 400,
                  'name': 'Cyber_Story',
                  'description': 'Short cyber comic',
                  'category': 'series',
                  'post_count': 1,
                  'post_ids': [4001],
                },
              ]),
              200,
            );
          }
          return http.Response(jsonEncode([]), 200);
        }

        if (path == '/posts.json') {
          final tags = params['tags'] ?? '';
          if (tags.contains('inpool:true')) {
            return http.Response(
              jsonEncode({
                'posts': [
                  {
                    'id': 5001,
                    'rating': 's',
                    'fav_count': 120,
                    'pools': [500],
                    'file': {'ext': 'jpg', 'url': 'https://example.com/5001.jpg'},
                    'preview': {'url': 'https://example.com/5001_p.jpg'},
                    'tags': {
                      'general': ['cyberpunk', 'neon'],
                    },
                  },
                  {
                    'id': 5002,
                    'rating': 's',
                    'fav_count': 180,
                    'pools': [500],
                    'file': {'ext': 'jpg', 'url': 'https://example.com/5002.jpg'},
                    'preview': {'url': 'https://example.com/5002_p.jpg'},
                    'tags': {
                      'general': ['cyberpunk', 'city'],
                    },
                  },
                ],
              }),
              200,
            );
          }
          if (tags.startsWith('id:')) {
            return http.Response(
              jsonEncode({
                'posts': [
                  {
                    'id': 4001,
                    'rating': 's',
                    'fav_count': 30,
                    'pools': [400],
                    'file': {'ext': 'jpg', 'url': 'https://example.com/4001.jpg'},
                    'preview': {'url': 'https://example.com/4001_p.jpg'},
                    'tags': {
                      'general': ['cyberpunk'],
                    },
                  },
                  {
                    'id': 5001,
                    'rating': 's',
                    'fav_count': 120,
                    'pools': [500],
                    'file': {'ext': 'jpg', 'url': 'https://example.com/5001.jpg'},
                    'preview': {'url': 'https://example.com/5001_p.jpg'},
                    'tags': {
                      'general': ['cyberpunk', 'neon'],
                    },
                  },
                  {
                    'id': 5002,
                    'rating': 's',
                    'fav_count': 180,
                    'pools': [500],
                    'file': {'ext': 'jpg', 'url': 'https://example.com/5002.jpg'},
                    'preview': {'url': 'https://example.com/5002_p.jpg'},
                    'tags': {
                      'general': ['cyberpunk', 'city'],
                    },
                  },
                ],
              }),
              200,
            );
          }
        }

        return http.Response(jsonEncode([]), 200);
      });

      final api = E621CollectionsApi(
        const {'User-Agent': 'Test'},
        client: mockClient,
        host: 'e926.net',
      );

      final results = await api.searchPools(
        query: 'cyberpunk',
        order: 'keyword_posts',
        keywordSearch: true,
      );

      expect(results, hasLength(2));
      // Pool 500 has 2 matching posts (300 total favs), Pool 400 has 1 matching post (30 total favs)
      expect(results.first.id, 500);
      expect(results.first.keywordMatchCount('cyberpunk'), 2);
      expect(results.first.totalFavCount, 300);
      expect(results.last.id, 400);
      expect(results.last.keywordMatchCount('cyberpunk'), 1);
    });

    test('searchPools forwards status/creator and only queries the selected scopes', () async {
      final seen = <Uri>[];
      final mockClient = MockClient((request) async {
        seen.add(request.url);
        return http.Response(jsonEncode([]), 200);
      });
      final api = E621CollectionsApi(
        const {'User-Agent': 'Test'},
        client: mockClient,
        host: 'e926.net',
      );

      await api.searchPools(
        query: 'dragon',
        category: 'series',
        isActive: true,
        creatorName: 'someone',
        inName: false,
        inDescription: true,
        inPosts: false,
      );

      expect(seen, hasLength(1));
      final params = seen.single.queryParameters;
      expect(seen.single.path, '/pools.json');
      expect(params.containsKey('search[name_matches]'), isFalse);
      expect(params['search[description_matches]'], '*dragon*');
      expect(params['search[category]'], 'series');
      expect(params['search[is_active]'], 'true');
      expect(params['search[creator_name]'], 'someone');
    });

    test('CollectionFilters normalizes invalid combinations', () {
      const broken = CollectionFilters(
        category: 'series',
        order: 'keyword_posts',
        inName: false,
        isActive: true,
      );
      final pools = broken.normalized(isPool: true);
      expect(pools.inName, isTrue); // always searches somewhere
      expect(pools.order, 'updated_at'); // needs post tags scope
      expect(pools.category, 'series');

      final sets = const CollectionFilters(category: 'series', inPosts: true, order: 'post_count')
          .normalized(isPool: false);
      expect(sets.category, isNull);
      expect(sets.inPosts, isTrue);
      expect(sets.order, 'updated_at');

      final setsKeyword = const CollectionFilters(inPosts: true, order: 'keyword_posts')
          .normalized(isPool: false);
      expect(setsKeyword.inPosts, isTrue);
      expect(setsKeyword.order, 'keyword_posts');

      expect(const CollectionFilters().advancedCount, 0);
      expect(
        const CollectionFilters(inPosts: true, minPosts: 10, creator: 'x', isActive: false)
            .advancedCount,
        4,
      );
    });

    test('matchesScope only looks at the chosen places', () {
      final pool = E621Collection(
        type: CollectionType.pool,
        id: 1,
        name: 'Quiet_Story',
        description: 'About a dragon',
        posts: [_buildPost(id: 1, species: ['wolf'])],
      );
      expect(pool.matchesScope('dragon'), isFalse);
      expect(pool.matchesScope('dragon', inDescription: true), isTrue);
      expect(pool.matchesScope('wolf', inPosts: true), isTrue);
      expect(pool.matchesScope('wolf', inName: true, inDescription: true), isFalse);
    });

    test('passesLocal checks category, isActive, creator, and minPosts; sortPools handles created_at', () {
      const filters = CollectionFilters(
        category: 'series',
        isActive: true,
        creator: 'Alice',
        minPosts: 5,
      );

      final matching = const E621Collection(
        type: CollectionType.pool,
        id: 10,
        name: 'Series_A',
        category: 'series',
        isActive: true,
        creatorName: 'alice',
        postCount: 6,
      );
      final wrongCategory = matching.copyWith(category: 'collection');
      final wrongActive = matching.copyWith(isActive: false);
      final wrongCreator = matching.copyWith(creatorName: 'bob');
      final tooFewPosts = matching.copyWith(postCount: 3);

      expect(filters.passesLocal(matching), isTrue);
      expect(filters.passesLocal(wrongCategory), isFalse);
      expect(filters.passesLocal(wrongActive), isFalse);
      expect(filters.passesLocal(wrongCreator), isFalse);
      expect(filters.passesLocal(tooFewPosts), isFalse);

      final older = E621Collection(
        type: CollectionType.pool,
        id: 1,
        name: 'Older',
        createdAt: DateTime.utc(2024, 1, 1),
      );
      final newer = E621Collection(
        type: CollectionType.pool,
        id: 2,
        name: 'Newer',
        createdAt: DateTime.utc(2025, 1, 1),
      );
      final sorted = E621CollectionsApi.sortPools([older, newer], order: 'created_at');
      expect(sorted.map((p) => p.id).toList(), [2, 1]);
    });

    testWidgets('CollectionsPage Pools tab displays filter chips and CollectionCard shows favs and matches',
        (WidgetTester tester) async {
      final storage = FakeSecureStorage();
      final authProvider = AuthProvider(storage: storage);
      final blacklistProvider = BlacklistProvider(storage: storage);
      final followsProvider = FollowsProvider(storage: storage);

      final samplePool = E621Collection(
        type: CollectionType.pool,
        id: 77,
        name: 'Dragon_Quest_Comic',
        postCount: 2,
        posts: [
          _buildPost(id: 1, favCount: 250, species: ['dragon']),
          _buildPost(id: 2, favCount: 300, species: ['dragon']),
        ],
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
            ChangeNotifierProvider<BlacklistProvider>.value(value: blacklistProvider),
            ChangeNotifierProvider<FollowsProvider>.value(value: followsProvider),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    height: 220,
                    width: 180,
                    child: CollectionCard(
                      collection: samplePool,
                      keywordMatchCount: 2,
                    ),
                  ),
                  const Expanded(child: CollectionsPage()),
                ],
              ),
            ),
          ),
        ),
      );

      // Verify CollectionCard displays summed favcount (550) and keyword match badge (2 matches)
      expect(find.text('550'), findsOneWidget);
      expect(find.text('2 matches'), findsOneWidget);

      // Switch to Pools tab in CollectionsPage
      await tester.tap(find.text('Pools'));
      await tester.pumpAndSettle();

      // Verify the simplified search header is rendered
      expect(find.text('Series'), findsOneWidget);
      expect(find.text('Collections'), findsOneWidget);
      expect(find.text('Updated'), findsOneWidget);
      expect(find.text('Most Favs'), findsNothing);
      expect(find.text('Keyword Search'), findsNothing);

      // Advanced options live in a bottom sheet
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      expect(find.text('Search options'), findsOneWidget);
      expect(find.text('Post tags'), findsOneWidget);

      await tester.tap(find.text('Post tags'));
      await tester.tap(find.text('50+'));
      await tester.pump();
      await tester.tap(find.text('Show results'));
      await tester.pumpAndSettle();

      // Applied filters show up as dismissible chips
      expect(find.text('In: Name + Post tags'), findsOneWidget);
      expect(find.text('50+ posts'), findsOneWidget);
    });
  });
}

