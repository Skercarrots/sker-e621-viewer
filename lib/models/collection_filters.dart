import 'collection_model.dart';

const Object _unset = Object();

/// Everything the user can tune when searching pools or sets.
///
/// Mirrors what e621 actually supports:
///  * `pools.json`      → name / description match, category, active state,
///                        creator, order (name, created_at, updated_at, post_count)
///  * `post_sets.json`  → name / description match, creator, order
///  * `posts.json`      → `inpool:true` + tags, used to find pools by what is inside
///
/// Sorts that e621 cannot do server-side (`fav_count`, `keyword_posts`) are
/// computed locally from the posts resolved for each card.
class CollectionFilters {
  static const defaultOrder = 'updated_at';
  static const minPostsChoices = [0, 5, 10, 25, 50, 100];

  /// Pools only: `null` (all), `series` or `collection`.
  final String? category;
  final String order;

  // What the query is matched against.
  final bool inName;
  final bool inDescription;

  /// Pools and sets: find collections through the tags of the posts inside them.
  final bool inPosts;

  /// Pools only: `true` = still updating, `false` = completed, `null` = any.
  final bool? isActive;

  /// Creator username (empty = anyone).
  final String creator;

  /// Client side minimum post count (0 = no limit).
  final int minPosts;

  const CollectionFilters({
    this.category,
    this.order = defaultOrder,
    this.inName = true,
    this.inDescription = false,
    this.inPosts = false,
    this.isActive,
    this.creator = '',
    this.minPosts = 0,
  });

  /// Searching beyond the name (description and/or post tags).
  bool get isBroadSearch => inDescription || inPosts;

  bool get hasDefaultScope => inName && !inDescription && !inPosts;

  /// Number of advanced filters in use. Category and sort are visible on the
  /// main screen so they are not counted here.
  int get advancedCount =>
      (hasDefaultScope ? 0 : 1) +
      (isActive != null ? 1 : 0) +
      (creator.trim().isNotEmpty ? 1 : 0) +
      (minPosts > 0 ? 1 : 0);

  bool get hasAdvanced => advancedCount > 0;

  String get scopeLabel {
    final parts = [
      if (inName) 'Name',
      if (inDescription) 'Description',
      if (inPosts) 'Post tags',
    ];
    return parts.join(' + ');
  }

  CollectionFilters copyWith({
    Object? category = _unset,
    String? order,
    bool? inName,
    bool? inDescription,
    bool? inPosts,
    Object? isActive = _unset,
    String? creator,
    int? minPosts,
  }) {
    return CollectionFilters(
      category: identical(category, _unset) ? this.category : category as String?,
      order: order ?? this.order,
      inName: inName ?? this.inName,
      inDescription: inDescription ?? this.inDescription,
      inPosts: inPosts ?? this.inPosts,
      isActive: identical(isActive, _unset) ? this.isActive : isActive as bool?,
      creator: creator ?? this.creator,
      minPosts: minPosts ?? this.minPosts,
    );
  }

  /// Drops the advanced filters but keeps category and sort.
  CollectionFilters clearAdvanced() => CollectionFilters(category: category, order: order);

  /// Makes sure the combination is valid for the given collection type.
  CollectionFilters normalized({required bool isPool}) {
    var f = this;
    if (!f.inName && !f.inDescription && !f.inPosts) f = f.copyWith(inName: true);
    if (!isPool) {
      f = f.copyWith(category: null, isActive: null);
    }
    if (f.order == 'keyword_posts' && !f.inPosts) f = f.copyWith(order: defaultOrder);
    final valid = isPool ? CollectionOrder.poolValues : CollectionOrder.setValues;
    if (!valid.contains(f.order)) f = f.copyWith(order: defaultOrder);
    return f;
  }

  /// Local part of the matching, used after results are merged client side.
  bool matchesQuery(E621Collection c, String query) {
    if (query.trim().isEmpty || !isBroadSearch) return true;
    return c.matchesScope(query, inName: inName, inDescription: inDescription, inPosts: inPosts);
  }

  bool passesLocal(E621Collection c) {
    if (c.postCount < minPosts) return false;
    if (c.isPool) {
      if (category != null && c.category != category) return false;
      if (isActive != null && c.isActive != isActive) return false;
    }
    final cleanCreator = creator.trim().toLowerCase();
    if (cleanCreator.isNotEmpty &&
        c.creatorName != null &&
        c.creatorName!.toLowerCase() != cleanCreator) {
      return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is CollectionFilters &&
      other.category == category &&
      other.order == order &&
      other.inName == inName &&
      other.inDescription == inDescription &&
      other.inPosts == inPosts &&
      other.isActive == isActive &&
      other.creator == creator &&
      other.minPosts == minPosts;

  @override
  int get hashCode =>
      Object.hash(category, order, inName, inDescription, inPosts, isActive, creator, minPosts);
}

/// Sort options available for each collection type.
class CollectionOrder {
  final String value;
  final String label;

  /// Compact label used on the sort button.
  final String shortLabel;

  /// One line explanation shown in the sort menu.
  final String hint;

  const CollectionOrder(this.value, this.label, this.shortLabel, this.hint);

  static const pools = [
    CollectionOrder('updated_at', 'Recently updated', 'Updated', 'Latest activity first'),
    CollectionOrder('created_at', 'Newest', 'Newest', 'Most recently created'),
    CollectionOrder('post_count', 'Most posts', 'Posts', 'Biggest pools first'),
    CollectionOrder('fav_count', 'Most favorited', 'Favorited', 'Sum of favorites of its posts'),
    CollectionOrder('keyword_posts', 'Most tag matches', 'Matches', 'Posts matching your search'),
    CollectionOrder('name', 'Name (A–Z)', 'A–Z', 'Alphabetical'),
  ];

  // `post_count` is left out on purpose: the biggest sets have huge payloads.
  static const sets = [
    CollectionOrder('updated_at', 'Recently updated', 'Updated', 'Latest activity first'),
    CollectionOrder('created_at', 'Newest', 'Newest', 'Most recently created'),
    CollectionOrder('fav_count', 'Most favorited', 'Favorited', 'Favorites of its latest posts'),
    CollectionOrder('keyword_posts', 'Most tag matches', 'Matches', 'Posts matching your search'),
    CollectionOrder('name', 'Name (A–Z)', 'A–Z', 'Alphabetical'),
  ];

  static List<String> get poolValues => pools.map((o) => o.value).toList();
  static List<String> get setValues => sets.map((o) => o.value).toList();
}

