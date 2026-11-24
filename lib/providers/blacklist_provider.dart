import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/collection_model.dart';
import '../models/post_model.dart';

/// Represents a single parsed blacklist rule (one line).
/// Multiple tags in the same line are treated as a logical AND (all must match),
/// while `~` tokens on a line act as a logical OR group (at least one must match).
class BlacklistRule {
  final String originalLine;
  final List<String> tokens;
  final List<_ParsedBlacklistToken> _requiredTokens;
  final List<_ParsedBlacklistToken> _orTokens;

  BlacklistRule({
    required this.originalLine,
    required this.tokens,
  })  : _requiredTokens = [],
        _orTokens = [] {
    for (final raw in tokens) {
      final lower = raw.toLowerCase();
      if (lower.startsWith('~') && lower.length > 1) {
        _orTokens.add(_ParsedBlacklistToken.parse(lower.substring(1), isNegated: false));
      } else if (lower.startsWith('-') && lower.length > 1) {
        _requiredTokens.add(_ParsedBlacklistToken.parse(lower.substring(1), isNegated: true));
      } else {
        _requiredTokens.add(_ParsedBlacklistToken.parse(lower, isNegated: false));
      }
    }
  }

  /// Evaluates whether this rule matches the given [post] and its [postTags].
  bool matches(E621Post post, Set<String> postTags) {
    if (_requiredTokens.isEmpty && _orTokens.isEmpty) return false;

    for (final token in _requiredTokens) {
      final matched = token.matchesPositive(post, postTags);
      if (token.isNegated ? matched : !matched) {
        return false;
      }
    }

    if (_orTokens.isNotEmpty &&
        !_orTokens.any((token) => token.matchesPositive(post, postTags))) {
      return false;
    }

    return true;
  }
}

class _ParsedBlacklistToken {
  final String core;
  final bool isNegated;
  final RegExp? wildcardRegex;

  const _ParsedBlacklistToken({
    required this.core,
    required this.isNegated,
    this.wildcardRegex,
  });

  factory _ParsedBlacklistToken.parse(String core, {required bool isNegated}) {
    RegExp? regex;
    if (!core.startsWith('rating:') && !core.startsWith('score:') && core.contains('*')) {
      final escaped = RegExp.escape(core).replaceAll(r'\*', '.*');
      regex = RegExp('^$escaped\$');
    }
    return _ParsedBlacklistToken(
      core: core,
      isNegated: isNegated,
      wildcardRegex: regex,
    );
  }

  bool matchesPositive(E621Post post, Set<String> postTags) {
    if (core.startsWith('rating:')) {
      final r = core.substring(7).trim();
      final postRating = post.rating.toLowerCase();
      if (r == 's' || r == 'safe') return postRating == 's' || postRating == 'safe';
      if (r == 'q' || r == 'questionable') return postRating == 'q' || postRating == 'questionable';
      if (r == 'e' || r == 'explicit') return postRating == 'e' || postRating == 'explicit';
      return postRating == r;
    }

    if (core.startsWith('score:')) {
      final valStr = core.substring(6).trim();
      if (valStr.startsWith('<=')) {
        final threshold = int.tryParse(valStr.substring(2));
        return threshold != null && post.score <= threshold;
      } else if (valStr.startsWith('>=')) {
        final threshold = int.tryParse(valStr.substring(2));
        return threshold != null && post.score >= threshold;
      } else if (valStr.startsWith('<')) {
        final threshold = int.tryParse(valStr.substring(1));
        return threshold != null && post.score < threshold;
      } else if (valStr.startsWith('>')) {
        final threshold = int.tryParse(valStr.substring(1));
        return threshold != null && post.score > threshold;
      } else {
        final exact = int.tryParse(valStr);
        return exact != null && post.score == exact;
      }
    }

    if (wildcardRegex != null) {
      return postTags.any(wildcardRegex!.hasMatch);
    }

    return postTags.contains(core);
  }
}

/// Manages client-side post blacklists and filter settings.
/// Persists locally on device so rules remain active across guest and authenticated sessions.
class BlacklistProvider with ChangeNotifier {
  final FlutterSecureStorage _storage;

  static const String storageKeyTags = 'blacklist_tags';
  static const String storageKeyEnabled = 'blacklist_enabled';
  static const String storageKeyPoolPosts = 'blacklist_pool_posts';
  static const String storageKeyHideBlacklistedPools = 'blacklist_hide_pools';
  static const String storageKeyHideEmptyCollections = 'blacklist_hide_empty_collections';

  static const String defaultBlacklist = 'young\nscat\nwatersports\nbestiality';

  String _rawBlacklist = defaultBlacklist;
  bool _isEnabled = true;
  bool _blacklistPoolPosts = false;
  bool _hideBlacklistedPools = false;
  bool _hideEmptyCollections = true;
  bool _isLoaded = false;

  List<BlacklistRule> _parsedRules = [];

  BlacklistProvider({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage() {
    _parseRules(_rawBlacklist);
  }

  String get rawBlacklist => _rawBlacklist;
  bool get isEnabled => _isEnabled;
  bool get blacklistPoolPosts => _blacklistPoolPosts;
  bool get hideBlacklistedPools => _hideBlacklistedPools;
  bool get hideEmptyCollections => _hideEmptyCollections;
  bool get isLoaded => _isLoaded;
  List<BlacklistRule> get parsedRules => List.unmodifiable(_parsedRules);
  int get ruleCount => _parsedRules.length;

  void _safeNotify() {
    try {
      if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          notifyListeners();
        });
        return;
      }
    } catch (_) {
      // Binding not initialized in isolated unit tests
    }
    notifyListeners();
  }

  /// Parses raw multiline string into active rules
  void _parseRules(String raw) {
    final lines = raw.split('\n');
    final List<BlacklistRule> rules = [];

    for (final rawLine in lines) {
      final trimmed = rawLine.trim();
      // Skip empty lines and comment lines starting with #
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final tokens = trimmed
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();

      if (tokens.isNotEmpty) {
        rules.add(BlacklistRule(originalLine: trimmed, tokens: tokens));
      }
    }

    _parsedRules = rules;
  }

  Future<void> loadSettings() async {
    try {
      final results = await Future.wait([
        _storage.read(key: storageKeyTags),
        _storage.read(key: storageKeyEnabled),
        _storage.read(key: storageKeyPoolPosts),
        _storage.read(key: storageKeyHideBlacklistedPools),
        _storage.read(key: storageKeyHideEmptyCollections),
      ]);

      final savedTags = results[0];
      final savedEnabled = results[1];
      final savedPool = results[2];
      final savedHidePools = results[3];
      final savedHideEmpty = results[4];

      final writes = <Future<void>>[];

      if (savedTags != null) {
        _rawBlacklist = savedTags;
      } else {
        _rawBlacklist = defaultBlacklist;
        writes.add(_storage.write(key: storageKeyTags, value: defaultBlacklist));
      }

      if (savedEnabled != null) {
        _isEnabled = savedEnabled == 'true';
      } else {
        _isEnabled = true;
        writes.add(_storage.write(key: storageKeyEnabled, value: 'true'));
      }

      if (savedPool != null) {
        _blacklistPoolPosts = savedPool == 'true';
      } else {
        _blacklistPoolPosts = false;
        writes.add(_storage.write(key: storageKeyPoolPosts, value: 'false'));
      }

      if (savedHidePools != null) {
        _hideBlacklistedPools = savedHidePools == 'true';
      } else {
        _hideBlacklistedPools = false;
        writes.add(_storage.write(key: storageKeyHideBlacklistedPools, value: 'false'));
      }

      if (savedHideEmpty != null) {
        _hideEmptyCollections = savedHideEmpty == 'true';
      } else {
        _hideEmptyCollections = true;
        writes.add(_storage.write(key: storageKeyHideEmptyCollections, value: 'true'));
      }

      if (writes.isNotEmpty) {
        await Future.wait(writes);
      }

      _parseRules(_rawBlacklist);
      _isLoaded = true;
      _safeNotify();
    } catch (e) {
      debugPrint('Error loading blacklist settings: $e');
      _rawBlacklist = defaultBlacklist;
      _parseRules(_rawBlacklist);
      _isLoaded = true;
      _safeNotify();
    }
  }

  Future<void> saveBlacklist(String newRawText) async {
    _rawBlacklist = newRawText;
    _parseRules(newRawText);
    await _storage.write(key: storageKeyTags, value: newRawText);
    _safeNotify();
  }

  /// Toggles whether blacklist filtering is globally enabled
  Future<void> setEnabled(bool enabled) async {
    if (_isEnabled == enabled) return;
    _isEnabled = enabled;
    await _storage.write(key: storageKeyEnabled, value: enabled ? 'true' : 'false');
    _safeNotify();
  }

  /// Toggles whether blacklist filtering applies to posts inside pools
  Future<void> setBlacklistPoolPosts(bool enabled) async {
    if (_blacklistPoolPosts == enabled) return;
    _blacklistPoolPosts = enabled;
    await _storage.write(key: storageKeyPoolPosts, value: enabled ? 'true' : 'false');
    _safeNotify();
  }

  /// Toggles whether pools containing blacklisted posts are hidden from pool results
  Future<void> setHideBlacklistedPools(bool enabled) async {
    if (_hideBlacklistedPools == enabled) return;
    _hideBlacklistedPools = enabled;
    await _storage.write(
      key: storageKeyHideBlacklistedPools,
      value: enabled ? 'true' : 'false',
    );
    _safeNotify();
  }

  /// Toggles whether pools and sets with 0 viewable images are hidden from grid results
  Future<void> setHideEmptyCollections(bool enabled) async {
    if (_hideEmptyCollections == enabled) return;
    _hideEmptyCollections = enabled;
    await _storage.write(
      key: storageKeyHideEmptyCollections,
      value: enabled ? 'true' : 'false',
    );
    _safeNotify();
  }

  Future<void> resetToDefault() async {
    await saveBlacklist(defaultBlacklist);
  }

  Future<void> clearAll() async {
    await saveBlacklist('');
  }

  /// Checks if a post matches any active blacklist rule
  bool isPostBlacklisted(E621Post post, {bool isPool = false}) {
    if (!_isEnabled) return false;
    if (isPool && !_blacklistPoolPosts) return false;
    if (_parsedRules.isEmpty) return false;

    final tags = post.allTags;
    for (final rule in _parsedRules) {
      if (rule.matches(post, tags)) {
        return true;
      }
    }
    return false;
  }

  /// Filters a list of posts, removing those that match the active blacklist
  List<E621Post> filterPosts(List<E621Post> posts, {bool isPool = false}) {
    if (!_isEnabled) return posts;
    if (isPool && !_blacklistPoolPosts) return posts;
    if (_parsedRules.isEmpty) return posts;

    return posts.where((post) => !isPostBlacklisted(post, isPool: isPool)).toList();
  }

  /// Returns the number of posts in [posts] that are hidden by the blacklist
  int countBlacklisted(List<E621Post> posts, {bool isPool = false}) {
    if (!_isEnabled) return 0;
    if (isPool && !_blacklistPoolPosts) return 0;
    if (_parsedRules.isEmpty) return 0;

    int count = 0;
    for (final post in posts) {
      if (isPostBlacklisted(post, isPool: isPool)) {
        count++;
      }
    }
    return count;
  }

  /// Checks if a pool contains any post matching the active blacklist rules.
  bool isPoolBlacklisted(E621Collection pool, {Iterable<E621Post>? posts}) {
    if (!_isEnabled || !_hideBlacklistedPools) return false;
    if (!pool.isPool) return false;
    if (_parsedRules.isEmpty) return false;

    final postsToCheck = posts ?? pool.posts;
    for (final post in postsToCheck) {
      final tags = post.allTags;
      for (final rule in _parsedRules) {
        if (rule.matches(post, tags)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Checks if a pool or set has 0 viewable images on the current host
  /// (e.g. when on e926 safe mode where non-safe posts are hidden, or when
  /// all resolved posts are hidden by the active blacklist).
  bool isCollectionEmpty(E621Collection collection, {bool isSafeMode = false}) {
    if (!_hideEmptyCollections) return false;
    if (collection.postCount <= 0 &&
        collection.postIds.isEmpty &&
        collection.posts.isEmpty) {
      return true;
    }
    if (collection.posts.isNotEmpty) {
      final hasAnyVisible = collection.posts.any((p) {
        if (p.previewUrl == null || p.previewUrl!.isEmpty) return false;
        if (isSafeMode && p.rating.toLowerCase() != 's') return false;
        if (isPostBlacklisted(p, isPool: collection.isPool)) return false;
        return true;
      });
      if (hasAnyVisible) return false;
      if (!isSafeMode && collection.postCount > collection.posts.length) {
        return false;
      }
      return true;
    }
    if (!isSafeMode && (collection.postCount > 0 || collection.postIds.isNotEmpty)) {
      return false;
    }
    return collection.coverUrl == null || collection.coverUrl!.isEmpty;
  }

  /// Filters a list of collections/pools, removing:
  /// - pools/sets with 0 viewable images when [hideEmptyCollections] is enabled
  /// - pools that contain blacklisted posts when [hideBlacklistedPools] is enabled
  List<E621Collection> filterPools(
    List<E621Collection> pools, {
    bool isSafeMode = false,
  }) {
    return pools.where((pool) {
      if (isCollectionEmpty(pool, isSafeMode: isSafeMode)) return false;
      if (isPoolBlacklisted(pool)) return false;
      return true;
    }).toList();
  }
}

