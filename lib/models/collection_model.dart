import 'dart:math' as math;
import 'post_model.dart';

/// The two kinds of community collections on e621.
enum CollectionType { pool, set }

/// Unified model for e621 pools and post sets, so cards, detail pages and
/// follows can share the same code.
class E621Collection {
  final CollectionType type;
  final int id;
  final String name;
  final String description;
  final int postCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Pools only: 'series' or 'collection'.
  final String? category;

  /// Pools only: whether the pool is still being updated.
  final bool isActive;

  /// Pools only. Name of the pool creator.
  final String? creatorName;

  /// Sets only. Used to query posts via `set:<shortname>`.
  final String? shortname;

  /// Pools: post ids in reading order. Sets: up to the last 5 post ids for cover/fav resolution.
  final List<int> postIds;

  /// Post used as the cover image.
  final int? coverPostId;

  /// Resolved preview/sample URL of [coverPostId].
  final String? coverUrl;

  /// Resolved posts belonging to this collection (used for blacklist checks).
  final List<E621Post> posts;

  /// Number of posts matched server-side by `/posts.json` during a tag search.
  final int serverMatchCount;

  const E621Collection({
    required this.type,
    required this.id,
    required this.name,
    this.description = '',
    this.postCount = 0,
    this.createdAt,
    this.updatedAt,
    this.category,
    this.isActive = false,
    this.creatorName,
    this.shortname,
    this.postIds = const [],
    this.coverPostId,
    this.coverUrl,
    this.posts = const [],
    this.serverMatchCount = 0,
  });

  bool get isPool => type == CollectionType.pool;
  bool get isSeries => isPool && category == 'series';

  /// e621 stores pool names with underscores instead of spaces.
  String get displayName => name.replaceAll('_', ' ');

  /// Unique key across pools and sets.
  String get key => '${type.name}:$id';

  /// Sum of [E621Post.favCount] across all resolved [posts] in this collection.
  int get totalFavCount => posts.fold<int>(0, (sum, p) => sum + p.favCount);

  /// Compact representation of [totalFavCount] (e.g. "1.2k", "450").
  String get formattedTotalFavCount {
    final total = totalFavCount;
    if (total >= 1000000) {
      return '${(total / 1000000).toStringAsFixed(1)}M';
    }
    if (total >= 10000) {
      return '${(total / 1000).round()}k';
    }
    if (total >= 1000) {
      return '${(total / 1000).toStringAsFixed(1)}k';
    }
    return '$total';
  }

  /// Counts how many resolved [posts] in this collection match all tokens in [query].
  int keywordMatchCount(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return 0;
    int count = 0;
    for (final post in posts) {
      if (post.matchesKeywordQuery(trimmed)) {
        count++;
      }
    }
    return math.max(count, serverMatchCount);
  }

  /// Checks whether this collection's own metadata (name, description, creator, shortname)
  /// matches all tokens in [query].
  bool matchesMetadataKeyword(String query) {
    return _tokensMatch(
      [
        name,
        displayName,
        description,
        if (creatorName != null) creatorName!,
        if (shortname != null) shortname!,
      ].join(' '),
      query,
    );
  }

  /// Checks whether this collection matches [query] in the selected scopes only:
  /// its [name] / shortname, its [description] and/or the resolved [posts] tags.
  /// Returns `true` when [query] is empty.
  bool matchesScope(
    String query, {
    bool inName = true,
    bool inDescription = false,
    bool inPosts = false,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return true;
    if (inName && _tokensMatch([name, displayName, if (shortname != null) shortname!].join(' '), trimmed)) {
      return true;
    }
    if (inDescription && _tokensMatch(description, trimmed)) return true;
    if (inPosts && keywordMatchCount(trimmed) > 0) return true;
    return false;
  }

  static bool _tokensMatch(String rawHaystack, String query) {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return true;
    final tokens = trimmed.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return true;
    final haystack = rawHaystack.toLowerCase();

    for (final rawToken in tokens) {
      final isNegated = (rawToken.startsWith('-') || rawToken.startsWith('~')) && rawToken.length > 1;
      final core = isNegated ? rawToken.substring(1) : rawToken;
      final norm = core.replaceAll(' ', '_');
      final spaced = core.replaceAll('_', ' ');
      final matched = haystack.contains(norm) || haystack.contains(spaced);
      if (isNegated && matched) return false;
      if (!isNegated && !matched) return false;
    }
    return true;
  }

  /// Checks whether this collection matches [query] either via its posts ([keywordMatchCount] > 0)
  /// or via its own metadata ([matchesMetadataKeyword]).
  bool matchesKeyword(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return true;
    if (keywordMatchCount(trimmed) > 0) return true;
    return matchesMetadataKeyword(trimmed);
  }

  static List<int> _parseIds(dynamic raw) {
    if (raw is! List) return const [];
    return raw.whereType<num>().map((e) => e.toInt()).toList();
  }

  factory E621Collection.fromPoolJson(Map<String, dynamic> json) {
    final ids = _parseIds(json['post_ids']);
    return E621Collection(
      type: CollectionType.pool,
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      postCount: (json['post_count'] as num?)?.toInt() ?? ids.length,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
      category: json['category']?.toString(),
      isActive: json['is_active'] == true,
      creatorName: json['creator_name']?.toString(),
      postIds: ids,
      // First page of a pool is the natural cover.
      coverPostId: ids.isNotEmpty ? ids.first : null,
    );
  }

  factory E621Collection.fromSetJson(Map<String, dynamic> json) {
    final rawIds = json['post_ids'];
    final sampleIds = <int>[];
    if (rawIds is List && rawIds.isNotEmpty) {
      final start = math.max(0, rawIds.length - 15);
      for (var i = rawIds.length - 1; i >= start; i--) {
        final v = rawIds[i];
        if (v is num) sampleIds.add(v.toInt());
      }
    }
    return E621Collection(
      type: CollectionType.set,
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      postCount: (json['post_count'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
      shortname: json['shortname']?.toString(),
      postIds: sampleIds,
      coverPostId: sampleIds.isNotEmpty ? sampleIds.first : null,
    );
  }

  E621Collection copyWith({
    String? name,
    String? description,
    int? postCount,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? category,
    bool? isActive,
    String? creatorName,
    String? shortname,
    List<int>? postIds,
    int? coverPostId,
    String? coverUrl,
    List<E621Post>? posts,
    int? serverMatchCount,
  }) {
    return E621Collection(
      type: type,
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      postCount: postCount ?? this.postCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      category: category ?? this.category,
      isActive: isActive ?? this.isActive,
      creatorName: creatorName ?? this.creatorName,
      shortname: shortname ?? this.shortname,
      postIds: postIds ?? this.postIds,
      coverPostId: coverPostId ?? this.coverPostId,
      coverUrl: coverUrl ?? this.coverUrl,
      posts: posts ?? this.posts,
      serverMatchCount: serverMatchCount ?? this.serverMatchCount,
    );
  }

  /// Local persistence (post ids are intentionally not stored).
  Map<String, dynamic> toLocalJson() => {
        'type': type.name,
        'id': id,
        'name': name,
        'description': description,
        'postCount': postCount,
        'updatedAt': updatedAt?.toIso8601String(),
        'category': category,
        'isActive': isActive,
        'creatorName': creatorName,
        'shortname': shortname,
        'coverPostId': coverPostId,
        'coverUrl': coverUrl,
      };

  factory E621Collection.fromLocalJson(Map<String, dynamic> json) {
    return E621Collection(
      type: json['type'] == 'set' ? CollectionType.set : CollectionType.pool,
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      postCount: (json['postCount'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
      category: json['category'] as String?,
      isActive: json['isActive'] == true,
      creatorName: json['creatorName'] as String?,
      shortname: json['shortname'] as String?,
      coverPostId: (json['coverPostId'] as num?)?.toInt(),
      coverUrl: json['coverUrl'] as String?,
    );
  }
}

/// A pool/set the user follows locally (e621 has no follow API).
class FollowedCollection {
  final E621Collection collection;

  /// Post count the last time the user opened this collection.
  final int lastSeenCount;
  final DateTime followedAt;

  const FollowedCollection({
    required this.collection,
    required this.lastSeenCount,
    required this.followedAt,
  });

  int get newCount => math.max(0, collection.postCount - lastSeenCount);

  FollowedCollection copyWith({E621Collection? collection, int? lastSeenCount}) {
    return FollowedCollection(
      collection: collection ?? this.collection,
      lastSeenCount: lastSeenCount ?? this.lastSeenCount,
      followedAt: followedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'collection': collection.toLocalJson(),
        'lastSeenCount': lastSeenCount,
        'followedAt': followedAt.toIso8601String(),
      };

  factory FollowedCollection.fromJson(Map<String, dynamic> json) {
    return FollowedCollection(
      collection: E621Collection.fromLocalJson(json['collection'] as Map<String, dynamic>),
      lastSeenCount: (json['lastSeenCount'] as num?)?.toInt() ?? 0,
      followedAt: DateTime.tryParse(json['followedAt']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

