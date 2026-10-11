import 'dart:math' as math;

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
  final DateTime? updatedAt;

  /// Pools only: 'series' or 'collection'.
  final String? category;

  /// Pools only: whether the pool is still being updated.
  final bool isActive;

  /// Pools only. Name of the pool creator.
  final String? creatorName;

  /// Sets only. Used to query posts via `set:<shortname>`.
  final String? shortname;

  /// Pools only: post ids in reading order. Empty for sets (sets can
  /// contain millions of ids, so we never keep them in memory).
  final List<int> postIds;

  /// Post used as the cover image.
  final int? coverPostId;

  /// Resolved preview/sample URL of [coverPostId].
  final String? coverUrl;

  const E621Collection({
    required this.type,
    required this.id,
    required this.name,
    this.description = '',
    this.postCount = 0,
    this.updatedAt,
    this.category,
    this.isActive = false,
    this.creatorName,
    this.shortname,
    this.postIds = const [],
    this.coverPostId,
    this.coverUrl,
  });

  bool get isPool => type == CollectionType.pool;
  bool get isSeries => isPool && category == 'series';

  /// e621 stores pool names with underscores instead of spaces.
  String get displayName => name.replaceAll('_', ' ');

  /// Unique key across pools and sets.
  String get key => '${type.name}:$id';

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
    int? cover;
    if (rawIds is List && rawIds.isNotEmpty && rawIds.last is num) {
      // Most recently added post.
      cover = (rawIds.last as num).toInt();
    }
    return E621Collection(
      type: CollectionType.set,
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      postCount: (json['post_count'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
      shortname: json['shortname']?.toString(),
      coverPostId: cover,
    );
  }

  E621Collection copyWith({
    String? name,
    String? description,
    int? postCount,
    DateTime? updatedAt,
    String? category,
    bool? isActive,
    String? creatorName,
    String? shortname,
    List<int>? postIds,
    int? coverPostId,
    String? coverUrl,
  }) {
    return E621Collection(
      type: type,
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      postCount: postCount ?? this.postCount,
      updatedAt: updatedAt ?? this.updatedAt,
      category: category ?? this.category,
      isActive: isActive ?? this.isActive,
      creatorName: creatorName ?? this.creatorName,
      shortname: shortname ?? this.shortname,
      postIds: postIds ?? this.postIds,
      coverPostId: coverPostId ?? this.coverPostId,
      coverUrl: coverUrl ?? this.coverUrl,
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

