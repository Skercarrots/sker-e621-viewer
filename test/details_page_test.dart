import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/pages/details_page.dart';
import 'package:skerdev_e621/providers/auth_provider.dart';
import 'package:skerdev_e621/providers/blacklist_provider.dart';
import 'package:skerdev_e621/providers/boards_provider.dart';
import 'package:skerdev_e621/providers/follows_provider.dart';
import 'package:skerdev_e621/providers/ref_boards_provider.dart';
import 'package:skerdev_e621/services/e621_collections_api.dart';
import 'widget_test.dart';

class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  int _nextId = 1;
  final Map<int, StreamController<VideoEvent>> streams = {};
  final Map<int, DataSource> dataSources = {};
  final Set<int> activeTextureIds = {};
  final Set<int> playingIds = {};
  final Set<int> loopingIds = {};
  final List<String> createdUrls = [];
  final List<VideoViewType> createdViewTypes = [];
  final Set<String> failingUrls = {};
  final Set<String> pendingUrls = {};
  final List<Duration> seeks = [];

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int textureId) async {
    activeTextureIds.remove(textureId);
    playingIds.remove(textureId);
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    return createWithOptions(
      VideoCreationOptions(
        dataSource: dataSource,
        viewType: VideoViewType.textureView,
      ),
    );
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    final ds = options.dataSource;
    dataSources[id] = ds;
    createdViewTypes.add(options.viewType);
    if (ds.uri != null) {
      createdUrls.add(ds.uri!);
    }
    activeTextureIds.add(id);
    streams[id] = StreamController<VideoEvent>(
      onCancel: () => (Completer<void>()..complete()).future,
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    final controller = streams[textureId];
    if (controller == null) return const Stream.empty();
    final ds = dataSources[textureId];
    if (ds?.uri != null && pendingUrls.contains(ds!.uri)) {
      return controller.stream;
    }
    Future.microtask(() {
      if (controller.isClosed) return;
      if (ds?.uri != null && failingUrls.contains(ds!.uri)) {
        controller.addError(
          PlatformException(code: 'VideoError', message: 'Codec failed for ${ds.uri}'),
        );
      } else {
        controller.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 5),
            size: const Size(1280, 720),
          ),
        );
      }
    });
    return controller.stream;
  }

  @override
  Future<void> setLooping(int textureId, bool looping) async {
    if (looping) {
      loopingIds.add(textureId);
    } else {
      loopingIds.remove(textureId);
    }
  }

  @override
  Future<void> play(int textureId) async {
    playingIds.add(textureId);
  }

  @override
  Future<void> pause(int textureId) async {
    playingIds.remove(textureId);
  }

  @override
  Future<void> setVolume(int textureId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async {}

  @override
  Future<void> seekTo(int textureId, Duration position) async {
    seeks.add(position);
  }

  @override
  Future<Duration> getPosition(int textureId) async => Duration.zero;

  @override
  Widget buildView(int textureId) => SizedBox(key: ValueKey('video-view-$textureId'));

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      SizedBox(key: ValueKey('video-view-${options.playerId}'));
}

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

  test('playableVideoUrls prefers full-size non-AV1 streams within a 1080p budget and puts AV1 last', () {
    Map<String, dynamic> alt(String md5, String ext, Map<String, dynamic> original, Map<String, dynamic> mp4,
        Map<String, dynamic> samples) {
      final base = 'https://static1.e621.net/data/${md5.substring(0, 2)}/${md5.substring(2, 4)}/$md5';
      return {
        'id': 1,
        'file': {'ext': ext, 'md5': md5, 'url': '$base.$ext'},
        'preview': {'url': 'https://static1.e621.net/data/preview/$md5.jpg'},
        'sample': {
          'has': true,
          'url': 'https://static1.e621.net/data/sample/$md5.jpg',
          'alternates': {
            'has': true,
            'original': {...original, 'url': '$base.$ext'},
            'variants': {
              'mp4': {...mp4, 'url': 'https://static1.e621.net/data/sample/${md5.substring(0, 2)}/${md5.substring(2, 4)}/${md5}_alt.mp4'},
            },
            'samples': samples,
          },
        },
        'tags': {'general': ['animated']},
      };
    }

    String sample(String md5, String name) =>
        'https://static1.e621.net/data/sample/${md5.substring(0, 2)}/${md5.substring(2, 4)}/${md5}_$name.mp4';

    // #2346230: VP8 webm 1102x620 -> original first, then equally sized H.264, then 480p.
    const md5a = '8cc585f75d4c0e909535d53a9541c9fe';
    final a = E621Post.fromJson(alt(
      md5a,
      'webm',
      {'codec': 'vp8', 'width': 1102, 'height': 620},
      {'codec': 'avc1.4D401E', 'width': 1102, 'height': 620},
      {
        '480p': {'codec': 'avc1.4D401E', 'width': 960, 'height': 540, 'url': sample(md5a, '480p')},
      },
    ));
    expect(a.playableVideoUrls.sublist(0, 3), [
      'https://static1.e621.net/data/8c/c5/$md5a.webm',
      sample(md5a, 'alt'),
      sample(md5a, '480p'),
    ]);

    // #4687420: AV1 mp4 1870x1052 -> full-size H.264 first, AV1 original last.
    const md5b = '072112f50b9de0669778eae2d852383b';
    final b = E621Post.fromJson(alt(
      md5b,
      'mp4',
      {'codec': 'av01.0.00M.08', 'width': 1870, 'height': 1052},
      {'codec': 'avc1.4D401E', 'width': 1870, 'height': 1052},
      {
        '480p': {'codec': 'avc1.4D401E', 'width': 960, 'height': 540, 'url': sample(md5b, '480p')},
        '720p': {'codec': 'avc1.4D401E', 'width': 1440, 'height': 810, 'url': sample(md5b, '720p')},
      },
    ));
    final urlsB = b.playableVideoUrls;
    expect(urlsB.sublist(0, 3), [
      sample(md5b, 'alt'),
      sample(md5b, '720p'),
      sample(md5b, '480p'),
    ]);
    expect(urlsB.indexOf('https://static1.e621.net/data/07/21/$md5b.mp4'), 3);
  });

  test('E621Post extracts videoVariants from sample.alternates and prioritizes mp4 in playableVideoUrls', () {
    final json = {
      'id': 5001,
      'file': {
        'ext': 'webm',
        'md5': 'aabbccddeeff00112233445566778899',
        'url': 'https://static1.e621.net/data/aa/bb/aabbccddeeff00112233445566778899.webm',
      },
      'preview': {
        'url': 'https://static1.e621.net/data/preview/aa/bb/aabbccddeeff00112233445566778899.jpg',
      },
      'sample': {
        'has': true,
        'url': 'https://static1.e621.net/data/sample/aa/bb/aabbccddeeff00112233445566778899.webm',
        'alternates': {
          'has': true,
          'variants': {
            'mp4': {
              'url': 'https://static1.e621.net/data/sample/aa/bb/aabbccddeeff00112233445566778899.mp4',
            },
          },
          'samples': {
            '720p': {
              'url': 'https://static1.e621.net/data/sample/aa/bb/aabbccddeeff00112233445566778899_720p.webm',
            },
          },
        },
      },
      'tags': {'general': ['animated']},
    };

    final post = E621Post.fromJson(json);
    expect(post.isVideo, isTrue);
    // previewUrl must remain the static JPG thumbnail, not the sample .webm
    expect(
      post.previewUrl,
      'https://static1.e621.net/data/preview/aa/bb/aabbccddeeff00112233445566778899.jpg',
    );
    final urls = post.playableVideoUrls;
    expect(
      urls.first,
      'https://static1.e621.net/data/sample/aa/bb/aabbccddeeff00112233445566778899.mp4',
    );
    expect(
      urls,
      contains('https://static1.e621.net/data/sample/aa/bb/aabbccddeeff00112233445566778899_720p.webm'),
    );
    expect(
      urls,
      contains('https://static1.e621.net/data/aa/bb/aabbccddeeff00112233445566778899.webm'),
    );
  });

  testWidgets('Video player disposes inactive controller on swipe and falls back when primary stream fails',
      (WidgetTester tester) async {
    final fakePlatform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fakePlatform;

    final fakeStorage = FakeSecureStorage();
    final authProvider = AuthProvider(storage: fakeStorage);
    final boardsProvider = BoardsProvider(storage: fakeStorage);
    final refBoardsProvider = RefBoardsProvider(storage: fakeStorage);

    // Make the first variant fail so it falls back to the second URL
    fakePlatform.failingUrls.add('https://example.com/broken_variant.mp4');

    final videoPost1 = E621Post(
      id: 6001,
      previewUrl: null,
      fileUrl: 'https://example.com/working_original.webm',
      extension: 'webm',
      videoVariants: ['https://example.com/broken_variant.mp4'],
      artistTags: ['video_artist'],
      characterTags: [],
      speciesTags: [],
      copyrightTags: [],
      generalTags: ['animated'],
    );

    final imagePost2 = E621Post(
      id: 6002,
      previewUrl: null,
      fileUrl: null,
      extension: 'png',
      artistTags: ['still_artist'],
      characterTags: [],
      speciesTags: [],
      copyrightTags: [],
      generalTags: ['still'],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<BoardsProvider>.value(value: boardsProvider),
          ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoardsProvider),
        ],
        child: MaterialApp(
          home: PostDetailPage(
            posts: [videoPost1, imagePost2],
            initialIndex: 0,
          ),
        ),
      ),
    );

    // Pump microtasks so failed first stream falls back and second stream initializes
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      fakePlatform.createdUrls,
      ['https://example.com/broken_variant.mp4', 'https://example.com/working_original.webm'],
    );
    expect(fakePlatform.activeTextureIds.length, 1);
    // Android must render through a native SurfaceView (platform view) to avoid
    // decoder-stride corruption in the texture path.
    expect(fakePlatform.createdViewTypes, everyElement(VideoViewType.platformView));
    final activeId = fakePlatform.activeTextureIds.first;
    expect(fakePlatform.loopingIds.contains(activeId), isTrue);
    expect(fakePlatform.playingIds.contains(activeId), isTrue);
    expect(find.byType(VideoPlayer), findsOneWidget);

    // Swipe to the second post -> the video controller on page 1 must be disposed immediately
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('File #6002'), findsOneWidget);
    expect(fakePlatform.activeTextureIds, isEmpty);
  });

  testWidgets('Swiping away while a video is still loading immediately cancels in-flight initialization',
      (WidgetTester tester) async {
    final fakePlatform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fakePlatform;

    final fakeStorage = FakeSecureStorage();
    final authProvider = AuthProvider(storage: fakeStorage);
    final boardsProvider = BoardsProvider(storage: fakeStorage);
    final refBoardsProvider = RefBoardsProvider(storage: fakeStorage);

    // Keep post 7001's video stuck in loading/buffering state
    fakePlatform.pendingUrls.add('https://example.com/slow_loading_video.mp4');

    final slowVideoPost = E621Post(
      id: 7001,
      previewUrl: null,
      fileUrl: 'https://example.com/slow_loading_video.mp4',
      extension: 'mp4',
      artistTags: ['video_artist'],
      characterTags: [],
      speciesTags: [],
      copyrightTags: [],
      generalTags: ['animated'],
    );

    final nextVideoPost = E621Post(
      id: 7002,
      previewUrl: null,
      fileUrl: 'https://example.com/next_video.mp4',
      extension: 'mp4',
      artistTags: ['next_artist'],
      characterTags: [],
      speciesTags: [],
      copyrightTags: [],
      generalTags: ['animated'],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<BoardsProvider>.value(value: boardsProvider),
          ChangeNotifierProvider<RefBoardsProvider>.value(value: refBoardsProvider),
        ],
        child: MaterialApp(
          home: PostDetailPage(
            posts: [slowVideoPost, nextVideoPost],
            initialIndex: 0,
          ),
        ),
      ),
    );

    await tester.pump();

    // Post 7001 created its video controller and is waiting on initialize(),
    // while offscreen neighbor Post 7002 has NOT created a controller.
    expect(fakePlatform.createdUrls, ['https://example.com/slow_loading_video.mp4']);
    expect(fakePlatform.activeTextureIds.length, 1);

    // Begin dragging horizontally past the 50% page change threshold
    final gesture = await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-500, 0));
    await tester.pump();

    // While the finger is still dragging, Post 7001's loading controller is disposed
    // at the 50% mark and Post 7002 does NOT start ExoPlayer init mid-swipe
    expect(fakePlatform.activeTextureIds, isEmpty);
    expect(fakePlatform.createdUrls, ['https://example.com/slow_loading_video.mp4']);

    // Release the swipe and let the ballistic snap animation finish
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // Once settled, Post 7002's controller is created and active
    expect(find.text('File #7002'), findsOneWidget);
    expect(fakePlatform.createdUrls, [
      'https://example.com/slow_loading_video.mp4',
      'https://example.com/next_video.mp4',
    ]);
    expect(fakePlatform.activeTextureIds.length, 1);
  });
}
