import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/models/board_model.dart';
import 'package:skerdev_e621/models/ref_board_model.dart';
import 'package:skerdev_e621/providers/ref_boards_provider.dart';

class FakeSecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> _data = {};

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
    return _data[key];
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
      _data[key] = value;
    } else {
      _data.remove(key);
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
    _data.remove(key);
  }
}

E621Post _dummyPost(int id) {
  return E621Post(
    id: id,
    previewUrl: 'https://static1.e621.net/preview/$id.jpg',
    fileUrl: 'https://static1.e621.net/file/$id.jpg',
    extension: 'jpg',
    artistTags: ['artist_test'],
    characterTags: [],
    speciesTags: [],
    copyrightTags: [],
    generalTags: ['solo'],
    score: 10,
    favCount: 5,
    rating: 's',
    description: '',
    isFavorited: false,
  );
}

void main() {
  group('RefBoard Models Tests', () {
    test('RefBoardItem serialization and deserialization', () {
      final post = _dummyPost(101);
      final item = RefBoardItem(
        id: 'item_1',
        postId: 101,
        imageUrl: post.fileUrl!,
        previewUrl: post.previewUrl,
        x: 150.0,
        y: 250.0,
        width: 300.0,
        height: 400.0,
        rotation: 0.5,
        isFlippedH: true,
        isFlippedV: false,
        isGrayscale: true,
        zIndex: 2,
        post: post,
      );

      final json = item.toJson();
      final fromJson = RefBoardItem.fromJson(json);

      expect(fromJson.id, 'item_1');
      expect(fromJson.postId, 101);
      expect(fromJson.imageUrl, post.fileUrl);
      expect(fromJson.x, 150.0);
      expect(fromJson.y, 250.0);
      expect(fromJson.width, 300.0);
      expect(fromJson.height, 400.0);
      expect(fromJson.rotation, 0.5);
      expect(fromJson.isFlippedH, true);
      expect(fromJson.isFlippedV, false);
      expect(fromJson.isGrayscale, true);
      expect(fromJson.zIndex, 2);
      expect(fromJson.post?.id, 101);
    });

    test('RefBoard serialization and deserialization', () {
      final item = RefBoardItem(
        id: 'item_1',
        imageUrl: 'https://example.com/test.jpg',
        x: 10,
        y: 20,
      );
      final now = DateTime.now();
      final board = RefBoard(
        id: 'board_1',
        name: 'Pose Studies',
        createdAt: now,
        updatedAt: now,
        items: [item],
        isLocked: true,
        backgroundColorHex: '#1E1E1E',
      );

      final json = board.toJson();
      final fromJson = RefBoard.fromJson(json);

      expect(fromJson.id, 'board_1');
      expect(fromJson.name, 'Pose Studies');
      expect(fromJson.isLocked, true);
      expect(fromJson.items.length, 1);
      expect(fromJson.items.first.imageUrl, 'https://example.com/test.jpg');
      expect(fromJson.itemCount, 1);
      expect(fromJson.coverUrl, 'https://example.com/test.jpg');
    });
  });

  group('RefBoardsProvider Operations', () {
    late FakeSecureStorage storage;
    late RefBoardsProvider provider;

    setUp(() {
      storage = FakeSecureStorage();
      provider = RefBoardsProvider(storage: storage);
    });

    test('creates a new ref board', () async {
      await provider.updateForUser('tester');
      final board = await provider.createRefBoard('Anatomy Studies');

      expect(provider.refBoards.length, 1);
      expect(provider.refBoards.first.name, 'Anatomy Studies');
      expect(board.items, isEmpty);
    });

    test('adds single post to a ref board with smart offset', () async {
      await provider.updateForUser('tester');
      final board = await provider.createRefBoard('Poses');

      final post1 = _dummyPost(1);
      final post2 = _dummyPost(2);

      await provider.addPostToRefBoard(board.id, post1);
      await provider.addPostToRefBoard(board.id, post2);

      final updated = provider.getRefBoardById(board.id)!;
      expect(updated.items.length, 2);
      expect(updated.items[0].postId, 1);
      expect(updated.items[1].postId, 2);
      // Second post should be placed horizontally after the first
      expect(updated.items[1].x, greaterThan(updated.items[0].x));
    });

    test('creates ref board from saved Board', () async {
      await provider.updateForUser('tester');

      final savedBoard = Board(
        id: 'saved_1',
        name: 'Dragons',
        createdAt: DateTime.now(),
        postIds: [10, 20, 30],
        posts: [_dummyPost(10), _dummyPost(20), _dummyPost(30)],
      );

      final refBoard = await provider.createFromSavedBoard(savedBoard);

      expect(refBoard.name, 'Ref: Dragons');
      expect(refBoard.items.length, 3);
      expect(refBoard.items.map((i) => i.postId), containsAll([10, 20, 30]));
    });

    test('imports entire saved board into an existing ref board', () async {
      await provider.updateForUser('tester');
      final refBoard = await provider.createRefBoard('Work Board');

      final savedBoard = Board(
        id: 'saved_2',
        name: 'Hands',
        createdAt: DateTime.now(),
        postIds: [100, 200],
        posts: [_dummyPost(100), _dummyPost(200)],
      );

      final count = await provider.addEntireBoardToRefBoard(refBoard.id, savedBoard);
      expect(count, 2);

      final updated = provider.getRefBoardById(refBoard.id)!;
      expect(updated.items.length, 2);
    });

    test('toggles horizontal flip, vertical flip, and grayscale', () async {
      await provider.updateForUser('tester');
      final board = await provider.createRefBoard('Flip Test');
      await provider.addPostToRefBoard(board.id, _dummyPost(55));

      final item = provider.getRefBoardById(board.id)!.items.first;
      expect(item.isFlippedH, false);
      expect(item.isFlippedV, false);
      expect(item.isGrayscale, false);

      await provider.toggleItemFlipH(board.id, item.id);
      expect(provider.getRefBoardById(board.id)!.items.first.isFlippedH, true);

      await provider.toggleItemFlipV(board.id, item.id);
      expect(provider.getRefBoardById(board.id)!.items.first.isFlippedV, true);

      await provider.toggleItemGrayscale(board.id, item.id);
      expect(provider.getRefBoardById(board.id)!.items.first.isGrayscale, true);
    });

    test('auto-arranges items in a neat grid (smart grid layout)', () async {
      await provider.updateForUser('tester');
      final board = await provider.createRefBoard('Arrange Test');
      for (int i = 0; i < 6; i++) {
        await provider.addPostToRefBoard(board.id, _dummyPost(i));
      }

      await provider.autoArrangeBoard(board.id, columns: 3);
      final updated = provider.getRefBoardById(board.id)!;

      // Col 0, Row 0
      expect(updated.items[0].x, 50.0);
      expect(updated.items[0].y, 50.0);

      // Col 1, Row 0
      expect(updated.items[1].x, greaterThan(updated.items[0].x));
      expect(updated.items[1].y, 50.0);

      // Col 0, Row 1
      expect(updated.items[3].x, 50.0);
      expect(updated.items[3].y, greaterThan(updated.items[0].y));
    });

    test('duplicates and deletes a ref board', () async {
      await provider.updateForUser('tester');
      final original = await provider.createRefBoard('Original Canvas');
      await provider.addPostToRefBoard(original.id, _dummyPost(1));

      final dup = await provider.duplicateRefBoard(original.id);
      expect(dup, isNotNull);
      expect(dup!.name, 'Original Canvas (Copy)');
      expect(dup.items.length, 1);
      expect(provider.refBoards.length, 2);

      await provider.deleteRefBoard(original.id);
      expect(provider.refBoards.length, 1);
      expect(provider.refBoards.first.id, dup.id);
    });

    test('persists boards across provider instances', () async {
      await provider.updateForUser('tester');
      await provider.createRefBoard('Persistent Canvas');

      // Create new provider with same storage
      final newProvider = RefBoardsProvider(storage: storage);
      await newProvider.updateForUser('tester');

      expect(newProvider.refBoards.length, 1);
      expect(newProvider.refBoards.first.name, 'Persistent Canvas');
    });

    test('persists reference boards between guest mode and logged in accounts', () async {
      // Start in guest mode
      await provider.updateForUser(null, isGuest: true);
      final guestBoard = await provider.createRefBoard('Guest Art Refs');
      expect(provider.refBoards.length, 1);
      expect(provider.refBoards.first.id, guestBoard.id);

      // Log in as user_beta - board persists!
      await provider.updateForUser('user_beta', isGuest: false);
      expect(provider.refBoards.length, 1);
      expect(provider.refBoards.first.id, guestBoard.id);

      // Create another board logged in
      await provider.createRefBoard('Account Art Refs');
      expect(provider.refBoards.length, 2);

      // Log out to guest mode - all remain persistent
      await provider.updateForUser(null, isGuest: true);
      expect(provider.refBoards.length, 2);
    });
  });
}
