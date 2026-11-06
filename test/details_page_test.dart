import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/pages/details_page.dart';
import 'package:skerdev_e621/providers/auth_provider.dart';
import 'package:skerdev_e621/providers/blacklist_provider.dart';
import 'package:skerdev_e621/providers/boards_provider.dart';
import 'package:skerdev_e621/providers/follows_provider.dart';
import 'package:skerdev_e621/providers/ref_boards_provider.dart';
import 'package:skerdev_e621/services/e621_collections_api.dart';
import 'widget_test.dart';

void main() {
  testWidgets('PostDetailPage supports swipe navigation between posts', (WidgetTester tester) async {
    final fakeStorage = FakeSecureStorage();
    final authProvider = AuthProvider(storage: fakeStorage);
    final boardsProvider = BoardsProvider(storage: fakeStorage);

    final post1 = E621Post(
      id: 1001,
      previewUrl: null,
      fileUrl: null,
      extension: 'jpg',
      artistTags: ['artist_one'],
      characterTags: [],
      speciesTags: [],
      copyrightTags: [],
      generalTags: ['fluffy'],
      score: 42,
    );

    final post2 = E621Post(
      id: 1002,
      previewUrl: null,
      fileUrl: null,
      extension: 'png',
      artistTags: ['artist_two'],
      characterTags: [],
      speciesTags: [],
      copyrightTags: [],
      generalTags: ['tail'],
      score: 99,
    );

    final refBoardsProvider = RefBoardsProvider(storage: fakeStorage);

    bool loadMoreCalled = false;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<BoardsProvider>.value(value: boardsProvider),
          ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoardsProvider),
        ],
        child: MaterialApp(
          home: PostDetailPage(
            posts: [post1, post2],
            initialIndex: 0,
            onLoadMore: () async {
              loadMoreCalled = true;
            },
          ),
        ),
      ),
    );

    // Initial state: first post is displayed
    expect(find.text('File #1001'), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);

    // Verify Download and Save to Board buttons are present in the AppBar
    expect(find.byTooltip('Download Art'), findsOneWidget);
    expect(find.byTooltip('Save to Board'), findsOneWidget);

    // Swipe left to go to the second post
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
    await tester.pump(const Duration(milliseconds: 600));

    // Second post is now visible
    expect(find.text('File #1002'), findsOneWidget);
    expect(find.text('2 of 2'), findsOneWidget);

    // onLoadMore should be triggered when nearing the end (index >= length - 3)
    expect(loadMoreCalled, isTrue);
  });

  testWidgets('PostDetailPage backward compatibility with single post constructor', (WidgetTester tester) async {
    final fakeStorage = FakeSecureStorage();
    final authProvider = AuthProvider(storage: fakeStorage);
    final boardsProvider = BoardsProvider(storage: fakeStorage);

    final singlePost = E621Post(
      id: 2001,
      previewUrl: null,
      fileUrl: null,
      extension: 'jpg',
      artistTags: ['solo_artist'],
      characterTags: [],
      speciesTags: [],
      copyrightTags: [],
      generalTags: [],
      score: 10,
    );

    final refBoardsProvider = RefBoardsProvider(storage: fakeStorage);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<BoardsProvider>.value(value: boardsProvider),
          ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoardsProvider),
        ],
        child: MaterialApp(
          home: PostDetailPage(post: singlePost),
        ),
      ),
    );

    expect(find.text('File #2001'), findsOneWidget);
    // When only 1 post is present, page counter is hidden
    expect(find.text('1 of 1'), findsNothing);
    // No pools or parent/children sections when empty
    expect(find.text('Pools'), findsNothing);
    expect(find.text('Parent Post'), findsNothing);
    expect(find.text('Children Posts'), findsNothing);
  });

  testWidgets('PostDetailPage displays pools, parent post, and children posts near tags and navigates on tap',
      (WidgetTester tester) async {
    final fakeStorage = FakeSecureStorage();
    final authProvider = AuthProvider(storage: fakeStorage);
    final boardsProvider = BoardsProvider(storage: fakeStorage);
    final refBoardsProvider = RefBoardsProvider(storage: fakeStorage);
    final followsProvider = FollowsProvider(storage: fakeStorage);
    final blacklistProvider = BlacklistProvider(storage: fakeStorage);

    final mockClient = MockClient((request) async {
      final path = request.url.path;
      final params = request.url.queryParameters;

      if (path == '/pools.json' && params['search[id]'] == '888') {
        return http.Response(
          jsonEncode([
            {
              'id': 888,
              'name': 'Starlight_Chronicles',
              'description': 'A sci-fi adventure comic',
              'category': 'series',
              'is_active': true,
              'post_count': 3,
              'post_ids': [3000, 3001, 3002],
            },
          ]),
          200,
        );
      }

      if (path == '/posts.json') {
        final tags = params['tags'] ?? '';
        if (tags.startsWith('id:')) {
          return http.Response(
            jsonEncode({
              'posts': [
                {
                  'id': 3000,
                  'rating': 's',
                  'score': {'total': 75},
                  'fav_count': 40,
                  'pools': [888],
                  'relationships': {
                    'parent_id': null,
                    'children': [3001],
                  },
                  'file': {'ext': 'jpg', 'url': 'https://example.com/3000.jpg'},
                  'preview': {'url': 'https://example.com/3000_p.jpg'},
                  'tags': {
                    'artist': ['space_artist'],
                    'general': ['spaceship'],
                  },
                },
                {
                  'id': 3002,
                  'rating': 's',
                  'score': {'total': 120},
                  'fav_count': 60,
                  'pools': [888],
                  'relationships': {
                    'parent_id': 3001,
                    'children': [],
                  },
                  'file': {'ext': 'png', 'url': 'https://example.com/3002.png'},
                  'preview': {'url': 'https://example.com/3002_p.jpg'},
                  'tags': {
                    'artist': ['space_artist'],
                    'general': ['stars'],
                  },
                },
                {
                  'id': 3003,
                  'rating': 's',
                  'score': {'total': 50},
                  'fav_count': 25,
                  'pools': [],
                  'relationships': {
                    'parent_id': 3001,
                    'children': [],
                  },
                  'file': {'ext': 'png', 'url': 'https://example.com/3003.png'},
                  'preview': {'url': 'https://example.com/3003_p.jpg'},
                  'tags': {
                    'artist': ['space_artist'],
                    'general': ['nebula'],
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

    final mainPost = E621Post(
      id: 3001,
      previewUrl: null,
      fileUrl: null,
      extension: 'jpg',
      artistTags: ['space_artist'],
      characterTags: ['astro_fox'],
      speciesTags: ['vulpes'],
      copyrightTags: [],
      generalTags: ['scifi'],
      score: 95,
      rating: 's',
      poolIds: [888],
      parentId: 3000,
      childrenIds: [3002, 3003],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<BoardsProvider>.value(value: boardsProvider),
          ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoardsProvider),
          ChangeNotifierProvider<FollowsProvider>.value(value: followsProvider),
          ChangeNotifierProvider<BlacklistProvider>.value(value: blacklistProvider),
        ],
        child: MaterialApp(
          home: PostDetailPage(
            post: mainPost,
            collectionsApi: api,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Pools section shows resolved pool name, category, page number, and pool ID
    expect(find.text('Pools'), findsOneWidget);
    expect(find.text('Starlight Chronicles'), findsOneWidget);
    expect(find.text('SERIES'), findsOneWidget);
    expect(find.text('Page 2 of 3'), findsOneWidget);
    expect(find.text('Pool #888'), findsOneWidget);

    // Parent Post and Children Posts sections are displayed near tags
    expect(find.text('Parent Post'), findsOneWidget);
    expect(find.text('Parent #3000'), findsOneWidget);
    expect(find.text('S • ↑ 75'), findsOneWidget);

    expect(find.text('Children Posts'), findsOneWidget);
    expect(find.text('Child #3002'), findsOneWidget);
    expect(find.text('S • ↑ 120'), findsOneWidget);
    expect(find.text('Child #3003'), findsOneWidget);
    expect(find.text('S • ↑ 50'), findsOneWidget);

    // Tapping Parent #3000 navigates to the parent post detail view
    await tester.ensureVisible(find.text('Parent #3000'));
    await tester.pump();
    await tester.tap(find.text('Parent #3000'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('File #3000'), findsOneWidget);
    expect(find.text('Child #3001'), findsOneWidget);
  });
}
