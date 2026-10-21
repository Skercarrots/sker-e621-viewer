import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/post_model.dart';

/// Represents a single parsed blacklist rule (one line).
/// Multiple tags in the same line are treated as a logical AND (all must match).
class BlacklistRule {
  final String originalLine;
  final List<String> tokens;

  BlacklistRule({
    required this.originalLine,
    required this.tokens,
  });

  /// Evaluates whether this rule matches the given [post] and its [postTags].
  bool matches(E621Post post, Set<String> postTags) {
    if (tokens.isEmpty) return false;
    for (final token in tokens) {
      if (!_matchesToken(token, post, postTags)) {
        return false;
      }
    }
    return true;
  }

  bool _matchesToken(String token, E621Post post, Set<String> postTags) {
    final lower = token.toLowerCase();

    // Negation prefix: '-' or '~'
    if ((lower.startsWith('-') || lower.startsWith('~')) && lower.length > 1) {
      final subToken = lower.substring(1);
      return !_matchesPositiveToken(subToken, post, postTags);
    }

    return _matchesPositiveToken(lower, post, postTags);
  }

  bool _matchesPositiveToken(String lower, E621Post post, Set<String> postTags) {
    // Rating matching (e.g. rating:s, rating:safe, rating:e, rating:explicit)
    if (lower.startsWith('rating:')) {
      final r = lower.substring(7).trim();
      final postRating = post.rating.toLowerCase();
      if (r == 's' || r == 'safe') return postRating == 's' || postRating == 'safe';
      if (r == 'q' || r == 'questionable') return postRating == 'q' || postRating == 'questionable';
      if (r == 'e' || r == 'explicit') return postRating == 'e' || postRating == 'explicit';
      return postRating == r;
    }

    // Score comparison (e.g. score:<10, score:>50)
    if (lower.startsWith('score:')) {
      final valStr = lower.substring(6).trim();
      if (valStr.startsWith('<')) {
        final threshold = int.tryParse(valStr.substring(1)) ?? 0;
        return post.score < threshold;
      } else if (valStr.startsWith('>')) {
        final threshold = int.tryParse(valStr.substring(1)) ?? 0;
        return post.score > threshold;
      } else {
        final exact = int.tryParse(valStr) ?? 0;
        return post.score == exact;
      }
    }

    // Wildcard matching (e.g. *gore* or blood*)
    if (lower.contains('*')) {
      final escaped = RegExp.escape(lower).replaceAll(r'\*', '.*');
      final regex = RegExp('^$escaped\$');
      return postTags.any((tag) => regex.hasMatch(tag));
    }

    // Exact tag matching
    return postTags.contains(lower);
  }
}

/// Manages client-side post blacklists and filter settings.
/// Persists locally on device so rules remain active across guest and authenticated sessions.
class BlacklistProvider with ChangeNotifier {
  final FlutterSecureStorage _storage;

  static const String storageKeyTags = 'blacklist_tags';
  static const String storageKeyEnabled = 'blacklist_enabled';
  static const String storageKeyPoolPosts = 'blacklist_pool_posts';

  static const String defaultBlacklist = 'young\nscat\nwatersports\nbestiality';

  String _rawBlacklist = defaultBlacklist;
  bool _isEnabled = true;
  bool _blacklistPoolPosts = false;
  bool _isLoaded = false;

  List<BlacklistRule> _parsedRules = [];

  BlacklistProvider({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage() {
    _parseRules(_rawBlacklist);
  }

  String get rawBlacklist => _rawBlacklist;
  bool get isEnabled => _isEnabled;
  bool get blacklistPoolPosts => _blacklistPoolPosts;
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

  /// Loads settings from secure storage
  Future<void> loadSettings() async {
    try {
      final savedTags = await _storage.read(key: storageKeyTags);
      if (savedTags != null) {
        _rawBlacklist = savedTags;
      } else {
        _rawBlacklist = defaultBlacklist;
        await _storage.write(key: storageKeyTags, value: defaultBlacklist);
      }

      final savedEnabled = await _storage.read(key: storageKeyEnabled);
      if (savedEnabled != null) {
        _isEnabled = savedEnabled == 'true';
      } else {
        _isEnabled = true;
        await _storage.write(key: storageKeyEnabled, value: 'true');
      }

      final savedPool = await _storage.read(key: storageKeyPoolPosts);
      if (savedPool != null) {
        _blacklistPoolPosts = savedPool == 'true';
      } else {
        _blacklistPoolPosts = false;
        await _storage.write(key: storageKeyPoolPosts, value: 'false');
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

  /// Updates and persists the blacklist tags text
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

  /// Resets blacklist tags to the default list
  Future<void> resetToDefault() async {
    await saveBlacklist(defaultBlacklist);
  }

  /// Clears all blacklist tags
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
}

