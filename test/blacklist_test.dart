import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:skerdev_e621/models/post_model.dart';
import 'package:skerdev_e621/providers/blacklist_provider.dart';

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
}

E621Post _makePost({
  required int id,
  List<String> artist = const [],
  List<String> character = const [],
  List<String> species = const [],
  List<String> copyright = const [],
  List<String> general = const [],
  String rating = 's',
  int score = 10,
}) {
  return E621Post(
    id: id,
    previewUrl: 'https://example.com/thumb_$id.jpg',
    fileUrl: 'https://example.com/file_$id.jpg',
    extension: 'jpg',
    artistTags: artist,
    characterTags: character,
    speciesTags: species,
    copyrightTags: copyright,
    generalTags: general,
    rating: rating,
    score: score,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BlacklistProvider Rule Engine Tests', () {
    late FakeSecureStorage storage;
    late BlacklistProvider provider;

    setUp(() {
      storage = FakeSecureStorage();
      provider = BlacklistProvider(storage: storage);
    });

    test('initializes with default blacklist tags', () {
      expect(provider.rawBlacklist, contains('young'));
      expect(provider.rawBlacklist, contains('scat'));
      expect(provider.rawBlacklist, contains('watersports'));
      expect(provider.rawBlacklist, contains('bestiality'));
      expect(provider.ruleCount, 4);
      expect(provider.isEnabled, isTrue);
      expect(provider.blacklistPoolPosts, isFalse);
    });

    test('matches single tag rule', () {
      final post1 = _makePost(id: 1, general: ['dragon', 'scat']);
      final post2 = _makePost(id: 2, general: ['dragon', 'fluffy']);

      expect(provider.isPostBlacklisted(post1), isTrue);
      expect(provider.isPostBlacklisted(post2), isFalse);
    });

    test('matches multi-tag AND rule on a single line', () async {
      await provider.saveBlacklist('cub male\nrating:e -solo');

      final cubMale = _makePost(id: 1, general: ['cub', 'male', 'canine']);
      final onlyCub = _makePost(id: 2, general: ['cub', 'female']);
      final onlyMale = _makePost(id: 3, general: ['adult', 'male']);

      expect(provider.isPostBlacklisted(cubMale), isTrue);
      expect(provider.isPostBlacklisted(onlyCub), isFalse);
      expect(provider.isPostBlacklisted(onlyMale), isFalse);
    });

    test('matches negation (-tag) in rule', () async {
      await provider.saveBlacklist('rating:e -solo');

      final eDuo = _makePost(id: 1, rating: 'e', general: ['duo']);
      final eSolo = _makePost(id: 2, rating: 'e', general: ['solo']);
      final sDuo = _makePost(id: 3, rating: 's', general: ['duo']);

      expect(provider.isPostBlacklisted(eDuo), isTrue); // explicit and not solo -> blacklisted
      expect(provider.isPostBlacklisted(eSolo), isFalse); // has solo -> not blacklisted
      expect(provider.isPostBlacklisted(sDuo), isFalse); // not explicit -> not blacklisted
    });

    test('matches wildcard tags with *', () async {
      await provider.saveBlacklist('*vore*');

      final softVore = _makePost(id: 1, general: ['soft_vore', 'dragon']);
      final hardVore = _makePost(id: 2, general: ['hard_vore_digest']);
      final noVore = _makePost(id: 3, general: ['flying', 'dragon']);

      expect(provider.isPostBlacklisted(softVore), isTrue);
      expect(provider.isPostBlacklisted(hardVore), isTrue);
      expect(provider.isPostBlacklisted(noVore), isFalse);
    });

    test('matches score thresholds', () async {
      await provider.saveBlacklist('score:<0');

      final negative = _makePost(id: 1, score: -5);
      final positive = _makePost(id: 2, score: 20);

      expect(provider.isPostBlacklisted(negative), isTrue);
      expect(provider.isPostBlacklisted(positive), isFalse);
    });

    test('ignores comments and empty lines', () async {
      await provider.saveBlacklist('''
# This is a comment
scat

# Another note
young
''');
      expect(provider.ruleCount, 2);
    });

    test('bypasses filtering when isEnabled is false', () async {
      final post = _makePost(id: 1, general: ['scat']);
      expect(provider.isPostBlacklisted(post), isTrue);

      await provider.setEnabled(false);
      expect(provider.isEnabled, isFalse);
      expect(provider.isPostBlacklisted(post), isFalse);

      final list = [post];
      expect(provider.filterPosts(list), hasLength(1));
    });

    test('respects blacklistPoolPosts toggle for pool posts', () async {
      final poolPost = _makePost(id: 1, general: ['scat']);

      // By default, blacklistPoolPosts is false -> pool posts not filtered
      expect(provider.isPostBlacklisted(poolPost, isPool: true), isFalse);
      expect(provider.filterPosts([poolPost], isPool: true), hasLength(1));

      // Normal feed posts ARE filtered
      expect(provider.isPostBlacklisted(poolPost, isPool: false), isTrue);
      expect(provider.filterPosts([poolPost], isPool: false), isEmpty);

      // Now enable pool filtering
      await provider.setBlacklistPoolPosts(true);
      expect(provider.blacklistPoolPosts, isTrue);
      expect(provider.isPostBlacklisted(poolPost, isPool: true), isTrue);
      expect(provider.filterPosts([poolPost], isPool: true), isEmpty);
    });

    test('persists settings and rules across provider instances', () async {
      await provider.saveBlacklist('gore\nblood');
      await provider.setEnabled(true);
      await provider.setBlacklistPoolPosts(true);

      // Create new instance with same storage
      final newProvider = BlacklistProvider(storage: storage);
      await newProvider.loadSettings();

      expect(newProvider.rawBlacklist, 'gore\nblood');
      expect(newProvider.ruleCount, 2);
      expect(newProvider.isEnabled, isTrue);
      expect(newProvider.blacklistPoolPosts, isTrue);
    });

    test('resets to default and clears all', () async {
      await provider.saveBlacklist('custom_tag');
      expect(provider.ruleCount, 1);

      await provider.resetToDefault();
      expect(provider.rawBlacklist, BlacklistProvider.defaultBlacklist);
      expect(provider.ruleCount, 4);

      await provider.clearAll();
      expect(provider.rawBlacklist, '');
      expect(provider.ruleCount, 0);
    });
  });
}

