import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Represents a single e621 tag or metatag suggestion.
class TagSuggestion {
  final int id;
  final String name;
  final int postCount;
  final int category;
  final String? antecedentName;

  const TagSuggestion({
    this.id = 0,
    required this.name,
    this.postCount = 0,
    this.category = 0,
    this.antecedentName,
  });

  factory TagSuggestion.fromJson(Map<String, dynamic> json) {
    final rawAntecedent = json['antecedent_name'];
    return TagSuggestion(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] as String?) ?? '',
      postCount: (json['post_count'] as num?)?.toInt() ?? 0,
      category: (json['category'] as num?)?.toInt() ?? 0,
      antecedentName: (rawAntecedent is String && rawAntecedent.trim().isNotEmpty)
          ? rawAntecedent.trim()
          : null,
    );
  }

  /// Human-readable category name matching e621 tag categories.
  String get categoryLabel {
    switch (category) {
      case 1:
        return 'Artist';
      case 3:
        return 'Copyright';
      case 4:
        return 'Character';
      case 5:
        return 'Species';
      case 6:
        return 'Invalid';
      case 7:
        return 'Meta';
      case 8:
        return 'Lore';
      case -1:
        return 'Filter';
      case 0:
      default:
        return 'General';
    }
  }

  /// Category color matching the tag chip colors in [PostDetailPage].
  Color get categoryColor {
    switch (category) {
      case 1:
        return Colors.redAccent;
      case 3:
        return Colors.purpleAccent;
      case 4:
        return Colors.greenAccent;
      case 5:
        return Colors.amberAccent;
      case 6:
        return Colors.red;
      case 7:
        return Colors.white70;
      case 8:
        return Colors.tealAccent;
      case -1:
        return Colors.cyanAccent;
      case 0:
      default:
        return Colors.blueAccent;
    }
  }

  /// Compact post count representation (e.g. "473k", "2.1M").
  String get formattedPostCount {
    if (postCount <= 0) return '';
    if (postCount >= 1000000) {
      return '${(postCount / 1000000).toStringAsFixed(1)}M';
    }
    if (postCount >= 10000) {
      return '${(postCount / 1000).round()}k';
    }
    if (postCount >= 1000) {
      return '${(postCount / 1000).toStringAsFixed(1)}k';
    }
    return '$postCount';
  }
}

/// Information about the tag token currently under the user's cursor.
class TagTokenContext {
  final String fullText;
  final int tokenStart;
  final int tokenEnd;
  final String prefixModifier; // e.g. '-' or '~' or ''
  final String query; // The tag body without prefixModifier

  const TagTokenContext({
    required this.fullText,
    required this.tokenStart,
    required this.tokenEnd,
    required this.prefixModifier,
    required this.query,
  });

  /// Extracts the active tag token at [cursorOffset] in [text].
  /// Returns `null` if the cursor is not currently touching a non-empty token.
  static TagTokenContext? extract(String text, int cursorOffset) {
    if (text.isEmpty) return null;
    final int safeCursor = cursorOffset.clamp(0, text.length);

    // If the character right before the cursor is whitespace (or we are at index 0)
    // AND the character at the cursor is whitespace/end, the user isn't mid-token.
    final bool prevIsSpace = safeCursor == 0 || _isWhitespace(text.codeUnitAt(safeCursor - 1));
    final bool nextIsSpace = safeCursor == text.length || _isWhitespace(text.codeUnitAt(safeCursor));
    if (prevIsSpace && nextIsSpace) {
      return null;
    }

    int start = safeCursor;
    while (start > 0 && !_isWhitespace(text.codeUnitAt(start - 1))) {
      start--;
    }

    int end = safeCursor;
    while (end < text.length && !_isWhitespace(text.codeUnitAt(end))) {
      end++;
    }

    final String rawToken = text.substring(start, end);
    if (rawToken.isEmpty) return null;

    String modifier = '';
    String core = rawToken;
    if (core.startsWith('-') || core.startsWith('~')) {
      modifier = core.substring(0, 1);
      core = core.substring(1);
    }

    if (core.isEmpty) return null;

    return TagTokenContext(
      fullText: text,
      tokenStart: start,
      tokenEnd: end,
      prefixModifier: modifier,
      query: core,
    );
  }

  /// Replaces the active token in [fullText] with [tagName] (preserving any
  /// `-` or `~` prefix modifier) and ensures a trailing space so the user can
  /// immediately type the next tag.
  TextEditingValue applySuggestion(String tagName) {
    final String before = fullText.substring(0, tokenStart);
    final String after = fullText.substring(tokenEnd);
    final String completedToken = '$prefixModifier$tagName';

    final bool afterStartsWithSpace = after.isNotEmpty && _isWhitespace(after.codeUnitAt(0));
    final String inserted = afterStartsWithSpace ? completedToken : '$completedToken ';
    final String newText = '$before$inserted$after';
    final int newCursor = before.length + (afterStartsWithSpace ? completedToken.length + 1 : inserted.length);

    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor.clamp(0, newText.length)),
    );
  }

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0A || codeUnit == 0x0D;
}

/// Service that fetches tag autocomplete suggestions from e621 and merges
/// built-in search metatags (like `order:score` or `rating:s`).
class TagAutocompleteService {
  static const String _host = 'e621.net';
  static const int _maxCacheEntries = 100;

  static const List<TagSuggestion> builtInMetatags = [
    TagSuggestion(name: 'order:score', category: -1),
    TagSuggestion(name: 'order:favcount', category: -1),
    TagSuggestion(name: 'order:id_desc', category: -1),
    TagSuggestion(name: 'order:random', category: -1),
    TagSuggestion(name: 'order:comment_count', category: -1),
    TagSuggestion(name: 'rating:s', category: -1),
    TagSuggestion(name: 'rating:q', category: -1),
    TagSuggestion(name: 'rating:e', category: -1),
    TagSuggestion(name: 'type:jpg', category: -1),
    TagSuggestion(name: 'type:png', category: -1),
    TagSuggestion(name: 'type:gif', category: -1),
    TagSuggestion(name: 'type:webm', category: -1),
    TagSuggestion(name: 'type:mp4', category: -1),
    TagSuggestion(name: 'is:parent', category: -1),
    TagSuggestion(name: 'is:child', category: -1),
    TagSuggestion(name: 'has:source', category: -1),
  ];

  final http.Client _client;
  final Map<String, List<TagSuggestion>> _cache = {};

  TagAutocompleteService({http.Client? client}) : _client = client ?? http.Client();

  /// Fetches suggestions for the active tag [query] (without leading `-` or `~`).
  Future<List<TagSuggestion>> fetchSuggestions(
    String query, {
    Map<String, String>? headers,
    int limit = 10,
  }) async {
    final normalized = query.trim().toLowerCase().replaceAll(' ', '_');
    if (normalized.isEmpty) return const [];

    // Check matching metatags (e.g. order:score, rating:s)
    final matchingMeta = builtInMetatags
        .where((m) => m.name.startsWith(normalized) && m.name != normalized)
        .toList();

    // If the user is typing a metatag with a colon (e.g. "order:", "rating:s"),
    // return the matching metatag suggestions directly without hitting the tag API.
    if (normalized.contains(':')) {
      return matchingMeta.take(limit).toList();
    }

    if (_cache.containsKey(normalized)) {
      return _cache[normalized]!.take(limit).toList();
    }

    final requestHeaders = headers ?? const {'User-Agent': 'SkerE621/1.0 (by anonymous on e621)'};
    List<TagSuggestion> apiSuggestions = const [];

    try {
      if (normalized.length >= 3) {
        // e621's dedicated autocomplete endpoint supports >= 3 characters and resolves aliases.
        final uri = Uri.https(_host, '/tags/autocomplete.json', {
          'search[name_matches]': normalized,
          'expiry': '7',
        });
        final response = await _client.get(uri, headers: requestHeaders);
        if (response.statusCode == 200) {
          final dynamic decoded = jsonDecode(response.body);
          if (decoded is List) {
            apiSuggestions = decoded
                .whereType<Map<String, dynamic>>()
                .map(TagSuggestion.fromJson)
                .where((t) => t.name.isNotEmpty)
                .toList();
          }
        }
      } else {
        // For 1-2 character prefixes, /tags/autocomplete.json returns 400, so use /tags.json.
        final uri = Uri.https(_host, '/tags.json', {
          'search[name_matches]': '$normalized*',
          'search[order]': 'count',
          'search[hide_empty]': 'true',
          'limit': '$limit',
        });
        final response = await _client.get(uri, headers: requestHeaders);
        if (response.statusCode == 200) {
          final dynamic decoded = jsonDecode(response.body);
          if (decoded is List) {
            apiSuggestions = decoded
                .whereType<Map<String, dynamic>>()
                .map(TagSuggestion.fromJson)
                .where((t) => t.name.isNotEmpty)
                .toList();
          }
        }
      }
    } catch (e) {
      debugPrint('TagAutocompleteService error for "$normalized": $e');
    }

    // Sort so direct tag matches appear above alias-redirected matches when appropriate,
    // and exact match is always first.
    apiSuggestions.sort((a, b) {
      final aExact = a.name == normalized;
      final bExact = b.name == normalized;
      if (aExact != bExact) return aExact ? -1 : 1;

      final aDirectPrefix = a.antecedentName == null && a.name.startsWith(normalized);
      final bDirectPrefix = b.antecedentName == null && b.name.startsWith(normalized);
      if (aDirectPrefix != bDirectPrefix) return aDirectPrefix ? -1 : 1;

      return b.postCount.compareTo(a.postCount);
    });

    final combined = <TagSuggestion>[
      ...apiSuggestions,
      for (final meta in matchingMeta)
        if (!apiSuggestions.any((t) => t.name == meta.name)) meta,
    ];

    if (combined.isNotEmpty) {
      if (_cache.length >= _maxCacheEntries) {
        _cache.remove(_cache.keys.first);
      }
      _cache[normalized] = combined;
    }

    return combined.take(limit).toList();
  }
}
