import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/models/board_model.dart';
import 'package:skerdev_e621/models/user_model.dart';
import 'package:skerdev_e621/providers/boards_provider.dart';
import 'package:skerdev_e621/providers/auth_provider.dart';

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

void main() {
  group('E621Post Model Tests', () {
    test('parses v2 format with mode=extended (grouped tags and nested files)', () {
      final v2Json = {
        "id": 4149486,
        "created_at": "2023-07-04T01:21:33.766-07:00",
        "updated_at": "2026-05-06T07:49:00.191-07:00",
        "change_seq": 70845555,
        "files": {
          "meta": {
            "md5": "402182a63c15d892a1861290dca4903c",
            "ext": "png",
            "size": 6749159,
            "duration": null,
            "has_sample": true
          },
          "original": {
            "width": 1874,
            "height": 1970,
            "url": "https://static1.e621.net/data/40/21/402182a63c15d892a1861290dca4903c.png"
          },
          "preview": {
            "width": 256,
            "height": 269,
            "jpg": "https://static1.e621.net/data/preview/40/21/402182a63c15d892a1861290dca4903c.jpg",
            "webp": "https://static1.e621.net/data/preview/40/21/402182a63c15d892a1861290dca4903c.webp"
          },
          "sample": {
            "width": 850,
            "height": 894,
            "jpg": "https://static1.e621.net/data/sample/40/21/402182a63c15d892a1861290dca4903c.jpg",
            "webp": "https://static1.e621.net/data/sample/40/21/402182a63c15d892a1861290dca4903c.webp"
          }
        },
        "uploader_id": 509791,
        "uploader_name": "gattonero2001",
        "approver_id": 12286,
        "stats": {
          "score": {
            "up": 3992,
            "down": -29,
            "total": 3963
          },
          "fav_count": 6125,
          "is_favorited": true,
          "vote": 1,
          "comment_count": 81
        },
        "rating": "s",
        "description": "Sample description",
        "tags": {
          "general": ["solo", "tail"],
          "artist": ["gattonero"],
          "character": ["char_a"],
          "species": ["feline"],
          "copyright": ["game_series"]
        }
      };

      final post = E621Post.fromJson(v2Json);

      expect(post.id, 4149486);
      expect(post.extension, 'png');
      expect(post.fileUrl, "https://static1.e621.net/data/40/21/402182a63c15d892a1861290dca4903c.png");
      expect(post.previewUrl, "https://static1.e621.net/data/sample/40/21/402182a63c15d892a1861290dca4903c.jpg");
      expect(post.artistTags, ["gattonero"]);
      expect(post.characterTags, ["char_a"]);
      expect(post.speciesTags, ["feline"]);
      expect(post.copyrightTags, ["game_series"]);
      expect(post.generalTags, ["solo", "tail"]);
      expect(post.score, 3963);
      expect(post.favCount, 6125);
      expect(post.isFavorited, isTrue);
      expect(post.rating, 's');
      expect(post.description, 'Sample description');
    });

    test('parses v2 format with mode=basic (flat tags list)', () {
      final v2BasicJson = {
        "id": 99999,
        "files": {
          "meta": {"ext": "webm"},
          "original": {"url": "https://static1.e621.net/data/video.webm"},
          "preview": {"jpg": "https://static1.e621.net/data/preview.jpg"},
        },
        "stats": {
          "score": {"total": 42},
          "fav_count": 10,
          "is_favorited": false,
        },
        "tags": ["animated", "dragon", "solo"],
      };

      final post = E621Post.fromJson(v2BasicJson);

      expect(post.id, 99999);
      expect(post.extension, 'webm');
      expect(post.fileUrl, "https://static1.e621.net/data/video.webm");
      expect(post.previewUrl, "https://static1.e621.net/data/preview.jpg");
      expect(post.generalTags, ["animated", "dragon", "solo"]);
      expect(post.artistTags, isEmpty);
      expect(post.score, 42);
      expect(post.favCount, 10);
      expect(post.isFavorited, isFalse);
    });

    test('parses legacy v1 format', () {
      final v1Json = {
        "id": 12345,
        "file": {
          "width": 1000,
          "height": 1000,
          "ext": "jpg",
          "size": 50000,
          "md5": "abc",
          "url": "https://static1.e621.net/data/abc.jpg"
        },
        "preview": {
          "url": "https://static1.e621.net/data/preview/abc.jpg"
        },
        "sample": {
          "has": true,
          "url": "https://static1.e621.net/data/sample/abc.jpg"
        },
        "score": {"total": 15},
        "fav_count": 5,
        "is_favorited": true,
        "tags": {
          "general": ["dog"],
          "artist": ["artist_name"],
          "character": [],
          "species": ["canine"],
          "copyright": []
        }
      };

      final post = E621Post.fromJson(v1Json);

      expect(post.id, 12345);
      expect(post.extension, 'jpg');
      expect(post.fileUrl, "https://static1.e621.net/data/abc.jpg");
      expect(post.previewUrl, "https://static1.e621.net/data/sample/abc.jpg");
      expect(post.artistTags, ["artist_name"]);
      expect(post.speciesTags, ["canine"]);
      expect(post.generalTags, ["dog"]);
      expect(post.score, 15);
      expect(post.favCount, 5);
      expect(post.isFavorited, isTrue);
    });

    test('handles roundtrip local json serialization for guest mode', () {
      final post = E621Post(
        id: 777,
        previewUrl: "https://preview.url",
        fileUrl: "https://file.url",
        extension: "png",
        artistTags: ["art1"],
        characterTags: ["char1"],
        speciesTags: ["spec1"],
        copyrightTags: ["copy1"],
        generalTags: ["gen1"],
        score: 100,
        favCount: 20,
        rating: "s",
        description: "Test description",
        isFavorited: true,
      );

      final serialized = post.toJson();
      final restored = E621Post.fromLocalJson(serialized);

      expect(restored.id, post.id);
      expect(restored.previewUrl, post.previewUrl);
      expect(restored.fileUrl, post.fileUrl);
      expect(restored.extension, post.extension);
      expect(restored.artistTags, post.artistTags);
      expect(restored.characterTags, post.characterTags);
      expect(restored.speciesTags, post.speciesTags);
      expect(restored.copyrightTags, post.copyrightTags);
      expect(restored.generalTags, post.generalTags);
      expect(restored.score, post.score);
      expect(restored.favCount, post.favCount);
      expect(restored.rating, post.rating);
      expect(restored.description, post.description);
      expect(restored.isFavorited, post.isFavorited);
    });
  });

  group('Board Model and BoardsProvider Tests', () {
    final samplePost1 = E621Post(
      id: 101,
      previewUrl: "https://sample.com/101.jpg",
      fileUrl: "https://sample.com/101_orig.jpg",
      extension: "jpg",
      artistTags: ["artist1"],
      characterTags: [],
      speciesTags: ["canine"],
      copyrightTags: [],
      generalTags: ["solo"],
    );

    final samplePost2 = E621Post(
      id: 102,
      previewUrl: "https://sample.com/102.png",
      fileUrl: "https://sample.com/102_orig.png",
      extension: "png",
      artistTags: ["artist2"],
      characterTags: ["dragon"],
      speciesTags: ["dragon"],
      copyrightTags: [],
      generalTags: ["wings"],
    );

    test('Board model roundtrip serialization', () {
      final board = Board(
        id: 'board-1',
        name: 'My Dragons',
        createdAt: DateTime(2026, 10, 4, 12, 0),
        postIds: [101, 102],
        posts: [samplePost1, samplePost2],
      );

      final json = board.toJson();
      final restored = Board.fromJson(json);

      expect(restored.id, 'board-1');
      expect(restored.name, 'My Dragons');
      expect(restored.postCount, 2);
      expect(restored.postIds, [101, 102]);
      expect(restored.posts.length, 2);
      expect(restored.coverUrl, "https://sample.com/101.jpg");
    });

    test('BoardsProvider CRUD operations and post toggle', () async {
      final fakeStorage = FakeSecureStorage();
      final provider = BoardsProvider(storage: fakeStorage);

      await provider.loadBoards();
      expect(provider.boards, isEmpty);

      // Create board
      final board = await provider.createBoard('Favorites 2026', initialPost: samplePost1);
      expect(provider.boards.length, 1);
      expect(provider.boards.first.name, 'Favorites 2026');
      expect(provider.boards.first.postIds, [101]);
      expect(provider.isPostInBoard(board.id, 101), isTrue);
      expect(provider.isPostInBoard(board.id, 102), isFalse);

      // Add second post
      final added = await provider.addPostToBoard(board.id, samplePost2);
      expect(added, isTrue);
      expect(provider.boards.first.postCount, 2);
      expect(provider.isPostInBoard(board.id, 102), isTrue);

      // Re-add duplicate post should return false
      final addedAgain = await provider.addPostToBoard(board.id, samplePost2);
      expect(addedAgain, isFalse);
      expect(provider.boards.first.postCount, 2);

      // Toggle post (should remove post 102)
      final toggledOut = await provider.togglePostInBoard(board.id, samplePost2);
      expect(toggledOut, isFalse);
      expect(provider.isPostInBoard(board.id, 102), isFalse);
      expect(provider.boards.first.postCount, 1);

      // Toggle post back in
      final toggledIn = await provider.togglePostInBoard(board.id, samplePost2);
      expect(toggledIn, isTrue);
      expect(provider.isPostInBoard(board.id, 102), isTrue);
      expect(provider.boards.first.postCount, 2);

      // Rename board
      final renamed = await provider.renameBoard(board.id, 'Best Dragons');
      expect(renamed, isTrue);
      expect(provider.boards.first.name, 'Best Dragons');

      // Reloading from storage retains all state
      final providerReloaded = BoardsProvider(storage: fakeStorage);
      await providerReloaded.loadBoards();
      expect(providerReloaded.boards.length, 1);
      expect(providerReloaded.boards.first.name, 'Best Dragons');
      expect(providerReloaded.boards.first.postCount, 2);

      // Delete board
      final deleted = await provider.deleteBoard(board.id);
      expect(deleted, isTrue);
      expect(provider.boards, isEmpty);
    });

    test('BoardsProvider persists boards between guest mode and user accounts', () async {
      final fakeStorage = FakeSecureStorage();
      final provider = BoardsProvider(storage: fakeStorage);

      // Guest mode
      await provider.updateForUser(null, isGuest: true);
      await provider.createBoard('Guest Folder');
      expect(provider.boards.length, 1);
      expect(provider.boards.first.name, 'Guest Folder');

      // User account logs in - boards persist
      await provider.updateForUser('user_alpha', isGuest: false);
      expect(provider.boards.length, 1);
      expect(provider.boards.first.name, 'Guest Folder');
      await provider.createBoard('Alpha Collection');
      expect(provider.boards.length, 2);

      // Switch back to guest - all local boards persist
      await provider.updateForUser(null, isGuest: true);
      expect(provider.boards.length, 2);
    });
  });

  group('E621User and Uploads Stats Tests', () {
    test('E621User parses json and computes avatarUrl fallback correctly', () {
      final userJson = {
        "id": 12345,
        "name": "ArtistFox",
        "level_string": "Member",
        "avatar_id": 99999,
        "post_count": 42,
        "favorite_count": 150,
      };

      final user = E621User.fromJson(userJson);

      expect(user.id, 12345);
      expect(user.name, "ArtistFox");
      expect(user.levelString, "Member");
      expect(user.avatarId, 99999);
      expect(user.postCount, 42);
      expect(user.favoriteCount, 150);

      // Without resolvedAvatarUrl, returns fallback
      expect(user.avatarUrl, "https://e621.net/images/user-avatar.png");

      // When resolvedAvatarUrl is populated
      user.resolvedAvatarUrl = "https://static1.e621.net/data/preview/sample.jpg";
      expect(user.avatarUrl, "https://static1.e621.net/data/preview/sample.jpg");
    });

    test('Computes total upvotes, likes, and arts count correctly across posts', () {
      final posts = [
        E621Post(
          id: 1,
          previewUrl: "https://e621.net/p1.jpg",
          extension: "png",
          artistTags: ["artist_one"],
          characterTags: [],
          speciesTags: [],
          copyrightTags: [],
          generalTags: [],
          score: 120,
          favCount: 85,
        ),
        E621Post(
          id: 2,
          previewUrl: "https://e621.net/p2.jpg",
          extension: "webm",
          artistTags: ["artist_one"],
          characterTags: [],
          speciesTags: [],
          copyrightTags: [],
          generalTags: [],
          score: -5,
          favCount: 15,
        ),
        E621Post(
          id: 3,
          previewUrl: "https://e621.net/p3.jpg",
          extension: "jpg",
          artistTags: ["artist_one"],
          characterTags: [],
          speciesTags: [],
          copyrightTags: [],
          generalTags: [],
          score: 300,
          favCount: 200,
        ),
      ];

      final totalUpvotes = posts.fold<int>(0, (sum, p) => sum + p.score);
      final totalLikes = posts.fold<int>(0, (sum, p) => sum + p.favCount);
      final totalArts = posts.length;

      expect(totalUpvotes, 415); // 120 - 5 + 300
      expect(totalLikes, 300);   // 85 + 15 + 200
      expect(totalArts, 3);
    });
  });

  group('Session and Boards Persistence Tests', () {
    test('AuthProvider immediately restores credentials, user profile and avatar from storage across sessions', () async {
      final fakeStorage = FakeSecureStorage();

      final cachedUser = E621User(
        id: 777,
        name: "SkerCreator",
        levelString: "Privileged",
        avatarId: 555,
        postCount: 15,
        favoriteCount: 88,
        resolvedAvatarUrl: "https://static1.e621.net/data/preview/cached_avatar.jpg",
      );

      // Pre-populate storage as if user logged in during a previous session
      await fakeStorage.write(key: 'username', value: 'SkerCreator');
      await fakeStorage.write(key: 'apiKey', value: 'secret_key_123');
      await fakeStorage.write(key: 'user_profile', value: jsonEncode(cachedUser.toJson()));

      // Launch a new app session with a new AuthProvider
      final auth = AuthProvider(storage: fakeStorage);
      expect(auth.isLoggedIn, isFalse);
      expect(auth.user, isNull);

      await auth.tryAutoLogin(refreshInBackground: false);

      // Verified: Session is restored immediately without relying on network
      expect(auth.isLoggedIn, isTrue);
      expect(auth.username, 'SkerCreator');
      expect(auth.user, isNotNull);
      expect(auth.user!.name, 'SkerCreator');
      expect(auth.user!.levelString, 'Privileged');
      expect(auth.user!.postCount, 15);
      expect(auth.user!.avatarUrl, 'https://static1.e621.net/data/preview/cached_avatar.jpg');
    });

    test('AuthProvider preserves Guest Mode across app sessions', () async {
      final fakeStorage = FakeSecureStorage();

      // Session 1: User enters guest mode
      final auth1 = AuthProvider(storage: fakeStorage);
      await auth1.setGuestMode(true);
      expect(auth1.isGuestMode, isTrue);

      // Session 2: User opens app again (new AuthProvider)
      final auth2 = AuthProvider(storage: fakeStorage);
      expect(auth2.isGuestMode, isFalse);

      await auth2.tryAutoLogin();
      expect(auth2.isGuestMode, isTrue);
      expect(auth2.isLoggedIn, isFalse);
    });

    test('BoardsProvider restores user boards across app sessions', () async {
      final fakeStorage = FakeSecureStorage();

      // Session 1: User creates boards and saves posts
      final boards1 = BoardsProvider(storage: fakeStorage);
      await boards1.updateForUser('SkerCreator', isGuest: false);

      final post = E621Post(
        id: 101,
        previewUrl: 'https://e621.net/preview101.jpg',
        extension: 'png',
        artistTags: ['artist_x'],
        characterTags: [],
        speciesTags: [],
        copyrightTags: [],
        generalTags: [],
      );

      final created = await boards1.createBoard('Best Arts', initialPost: post);
      expect(boards1.boards.length, 1);
      expect(boards1.boards.first.id, created.id);
      expect(boards1.boards.first.postIds, contains(101));

      // Session 2: Fresh app launch (new BoardsProvider instance)
      final boards2 = BoardsProvider(storage: fakeStorage);
      await boards2.updateForUser('SkerCreator', isGuest: false);

      expect(boards2.boards.length, 1);
      expect(boards2.boards.first.name, 'Best Arts');
      expect(boards2.boards.first.postIds, [101]);
      expect(boards2.boards.first.posts.first.previewUrl, 'https://e621.net/preview101.jpg');
    });
  });
}
