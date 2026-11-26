import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/collection_model.dart';
import '../models/post_model.dart';
import '../services/local_data_vault.dart';

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
  final LocalDataVault? _vault;

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

  BlacklistProvider({FlutterSecureStorage? storage, LocalDataVault? vault})
      : _storage = storage ?? const FlutterSecureStorage(),
        _vault = vault {
    _parseRules(_rawBlacklist);
  }

  Future<String?> _readKey(String key) async {
    if (_vault != null) {
      final fromVault = await _vault.read(key);
      if (fromVault != null) return fromVault;
    }
    return _storage.read(key: key);
  }

  Future<void> _writeKey(String key, String value) async {
    if (_vault != null) {
      await _vault.write(key, value);
    } else {
      await _storage.write(key: key, value: value);
    }
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
        _readKey(storageKeyTags),
        _readKey(storageKeyEnabled),
        _readKey(storageKeyPoolPosts),
        _readKey(storageKeyHideBlacklistedPools),
        _readKey(storageKeyHideEmptyCollections),
      ]);

      final savedTags = results[0];
      final savedEnabled = results[1];
      final savedPool = results[2];
      final savedHidePools = results[3];
      final savedHideEmpty = results[4];

      final defaultWrites = <String, String>{};

      if (savedTags != null) {
        _rawBlacklist = savedTags;
      } else {
        _rawBlacklist = defaultBlacklist;
        defaultWrites[storageKeyTags] = defaultBlacklist;
      }

      if (savedEnabled != null) {
        _isEnabled = savedEnabled == 'true';
      } else {
        _isEnabled = true;
        defaultWrites[storageKeyEnabled] = 'true';
      }

      if (savedPool != null) {
        _blacklistPoolPosts = savedPool == 'true';
      } else {
        _blacklistPoolPosts = false;
        defaultWrites[storageKeyPoolPosts] = 'false';
      }

      if (savedHidePools != null) {
        _hideBlacklistedPools = savedHidePools == 'true';
      } else {
        _hideBlacklistedPools = false;
        defaultWrites[storageKeyHideBlacklistedPools] = 'false';
      }

      if (savedHideEmpty != null) {
        _hideEmptyCollections = savedHideEmpty == 'true';
      } else {
        _hideEmptyCollections = true;
        defaultWrites[storageKeyHideEmptyCollections] = 'true';
      }

      if (defaultWrites.isNotEmpty) {
        if (_vault != null) {
          await _vault.writeAll(defaultWrites);
        } else {
          await Future.wait([
            for (final e in defaultWrites.entries)
              _storage.write(key: e.key, value: e.value),
          ]);
        }
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
    await _writeKey(storageKeyTags, newRawText);
    _safeNotify();
  }

  /// Toggles whether blacklist filtering is globally enabled
  Future<void> setEnabled(bool enabled) async {
    if (_isEnabled == enabled) return;
    _isEnabled = enabled;
    await _writeKey(storageKeyEnabled, enabled ? 'true' : 'false');
    _safeNotify();
  }

  /// Toggles whether blacklist filtering applies to posts inside pools
  Future<void> setBlacklistPoolPosts(bool enabled) async {
    if (_blacklistPoolPosts == enabled) return;
    _blacklistPoolPosts = enabled;
    await _writeKey(storageKeyPoolPosts, enabled ? 'true' : 'false');
    _safeNotify();
  }

  /// Toggles whether pools containing blacklisted posts are hidden from pool results
  Future<void> setHideBlacklistedPools(bool enabled) async {
    if (_hideBlacklistedPools == enabled) return;
    _hideBlacklistedPools = enabled;
    await _writeKey(
      storageKeyHideBlacklistedPools,
      enabled ? 'true' : 'false',
    );
    _safeNotify();
  }

  /// Toggles whether pools and sets with 0 viewable images are hidden from grid results
  Future<void> setHideEmptyCollections(bool enabled) async {
    if (_hideEmptyCollections == enabled) return;
    _hideEmptyCollections = enabled;
    await _writeKey(
      storageKeyHideEmptyCollections,
      enabled ? 'true' : 'false',
    );
    _safeNotify();
  }

  Future<void> resetToDefault() async {
    await saveBlacklist(defaultBlacklist);
  }

  Future<void> clearAll() async {
    await saveBlacklist('');
  }

  /// Checks whether an exact single-line rule exists (case-insensitive).
  bool hasExactRule(String rule) {
    final target = rule.trim().toLowerCase();
    if (target.isEmpty) return false;
    for (final line in _rawBlacklist.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (trimmed.toLowerCase() == target) {
        return true;
      }
    }
    return false;
  }

  /// Appends a single-line blacklist rule if not already present.
  Future<bool> addRule(String rule) async {
    final trimmed = rule.trim();
    if (trimmed.isEmpty || hasExactRule(trimmed)) return false;

    final current = _rawBlacklist.trimRight();
    final updated = current.isEmpty ? trimmed : '$current\n$trimmed';
    await saveBlacklist(updated);
    return true;
  }

  /// Removes any exact single-line rule matching [rule] (case-insensitive).
  Future<bool> removeExactRule(String rule) async {
    final target = rule.trim().toLowerCase();
    if (target.isEmpty) return false;

    final lines = _rawBlacklist.split('\n');
    final kept = <String>[];
    bool removed = false;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('#') &&
          trimmed.toLowerCase() == target) {
        removed = true;
        continue;
      }
      kept.add(line);
    }

    if (!removed) return false;
    await saveBlacklist(kept.join('\n').trimRight());
    return true;
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

