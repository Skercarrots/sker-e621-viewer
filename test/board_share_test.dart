import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:skerdev_e621/models/board_model.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/models/ref_board_model.dart';
import 'package:skerdev_e621/providers/boards_provider.dart';
import 'package:skerdev_e621/providers/ref_boards_provider.dart';
import 'package:skerdev_e621/services/board_share_service.dart';

class _FakeSecureStorage extends Fake implements FlutterSecureStorage {
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
}

void main() {
  group('BoardShareService Codec & Deep Link Tests', () {
    test('Encodes and decodes a Saved Board via share code and deep link', () {
      final board = Board(
        id: 'b_123',
        name: 'Cool Dragons',
        createdAt: DateTime(2026, 11, 5),
        postIds: [4149486, 4021999, 3999111],
        posts: const [],
      );

      final code = BoardShareService.encodeBoard(board, author: 'SkerFriend');
      expect(code.startsWith('SKER-B1:'), isTrue);

      final decodedFromCode = BoardShareService.tryDecodeAny(code);
      expect(decodedFromCode, isNotNull);
      expect(decodedFromCode!.isRefCanvas, isFalse);
      expect(decodedFromCode.name, 'Cool Dragons');
      expect(decodedFromCode.author, 'SkerFriend');
      expect(decodedFromCode.postIds, [4149486, 4021999, 3999111]);

      // Also verify decoding from a full invite chat message containing deep link & code
      final message = BoardShareService.buildShareMessage(
        name: board.name,
        itemCount: board.postCount,
        isRefCanvas: false,
        shareCode: code,
      );
      final decodedFromMessage = BoardShareService.tryDecodeAny(message);
      expect(decodedFromMessage, isNotNull);
      expect(decodedFromMessage!.name, 'Cool Dragons');
      expect(decodedFromMessage.postIds, [4149486, 4021999, 3999111]);
    });

    test('Encodes and decodes a Ref Canvas preserving 2D positions, flips, and grayscale', () {
      final refBoard = RefBoard(
        id: 'ref_1',
        name: 'Anatomy Study',
        createdAt: DateTime(2026, 11, 5),
        updatedAt: DateTime(2026, 11, 5),
        isLocked: true,
        backgroundColorHex: '#121212',
        items: const [
          RefBoardItem(
            id: 'item_1',
            postId: 4149486,
            imageUrl: 'https://static1.e621.net/data/a.png',
            x: 120.0,
            y: 340.0,
            width: 300.0,
            height: 420.0,
            rotation: 0.25,
            isFlippedH: true,
            isFlippedV: false,
            isGrayscale: true,
            zIndex: 2,
          ),
          RefBoardItem(
            id: 'item_2',
            postId: 4021999,
            imageUrl: 'https://static1.e621.net/data/b.png',
            x: 500.0,
            y: 100.0,
            width: 260.0,
            height: 360.0,
            rotation: 0.0,
            isFlippedH: false,
            isFlippedV: true,
            isGrayscale: false,
            zIndex: 1,
          ),
        ],
      );

      final code = BoardShareService.encodeRefBoard(refBoard, author: 'ArtistA');
      expect(code.startsWith('SKER-R1:'), isTrue);

      final decoded = BoardShareService.tryDecodeAny(code);

      expect(decoded, isNotNull);
      expect(decoded!.isRefCanvas, isTrue);
      expect(decoded.name, 'Anatomy Study');
      expect(decoded.author, 'ArtistA');
      expect(decoded.isLocked, isTrue);
      expect(decoded.backgroundColorHex, '#121212');
      expect(decoded.refItems.length, 2);
      expect(decoded.allReferencedPostIds, [4149486, 4021999]);

      final first = decoded.refItems[0];
      expect(first.postId, 4149486);
      expect(first.x, 120.0);
      expect(first.y, 340.0);
      expect(first.width, 300.0);
      expect(first.height, 420.0);
      expect(first.rotation, closeTo(0.25, 0.001));
      expect(first.isFlippedH, isTrue);
      expect(first.isFlippedV, isFalse);
      expect(first.isGrayscale, isTrue);
      expect(first.zIndex, 2);

      final second = decoded.refItems[1];
      expect(second.postId, 4021999);
      expect(second.isFlippedH, isFalse);
      expect(second.isFlippedV, isTrue);
      expect(second.isGrayscale, isFalse);
      expect(second.zIndex, 1);
    });

    test('BoardsProvider and RefBoardsProvider import shared payloads and persist them', () async {
      final storage = _FakeSecureStorage();
      final boardsProvider = BoardsProvider(storage: storage);
      final refProvider = RefBoardsProvider(storage: storage);

      final samplePost = E621Post(
        id: 4149486,
        previewUrl: 'https://static1.e621.net/preview.jpg',
        fileUrl: 'https://static1.e621.net/full.png',
        extension: 'png',
        artistTags: const ['artist'],
        characterTags: const [],
        speciesTags: const ['dragon'],
        copyrightTags: const [],
        generalTags: const ['solo'],
      );

      final importedBoard = await boardsProvider.importSharedBoard(
        name: 'Friend Dragons',
        postIds: [4149486],
        posts: [samplePost],
      );
      expect(boardsProvider.boards.length, 1);
      expect(importedBoard.name, 'Friend Dragons');
      expect(importedBoard.postIds, [4149486]);

      final sharedItem = const SharedRefItemData(
        postId: 4149486,
        x: 80,
        y: 90,
        width: 280,
        height: 380,
        isFlippedH: true,
        isGrayscale: true,
        zIndex: 3,
      ).toRefBoardItem(0, hydratedPost: samplePost);

      final importedRef = await refProvider.importSharedRefBoard(
        name: 'Friend Canvas',
        items: [sharedItem],
      );
      expect(refProvider.refBoards.length, 1);
      expect(importedRef.name, 'Friend Canvas');
      expect(importedRef.items.first.isFlippedH, isTrue);
      expect(importedRef.items.first.isGrayscale, isTrue);
      expect(importedRef.items.first.post?.id, 4149486);
    });
  });
}

