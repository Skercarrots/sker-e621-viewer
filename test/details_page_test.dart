import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/pages/details_page.dart';
import 'package:skerdev_e621/providers/auth_provider.dart';
import 'package:skerdev_e621/providers/boards_provider.dart';
import 'package:skerdev_e621/providers/ref_boards_provider.dart';
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
  });
}
