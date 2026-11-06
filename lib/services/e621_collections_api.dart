import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/collection_model.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';

// Top-level so they can run in a background isolate via `compute`.
// Set responses may contain millions of post ids, so decoding them on the
// UI thread would freeze the app.
List<E621Collection> _parsePools(String body) {
  final data = jsonDecode(body);
  if (data is! List) return const [];
  return data.whereType<Map<String, dynamic>>().map(E621Collection.fromPoolJson).toList();
}

List<E621Collection> _parseSets(String body) {
  final data = jsonDecode(body);
  if (data is! List) return const [];
  return data.whereType<Map<String, dynamic>>().map(E621Collection.fromSetJson).toList();
}

/// Thin client for e621 / e926 pools / post sets endpoints.
class E621CollectionsApi {
  static const _maxIdsPerQuery = 100;
  static const _maxPoolPostsToInspect = 5;
  static final Map<String, E621Post> _postCache = {};
  static final Map<String, E621Collection> _poolCache = {};

  final Map<String, String> headers;
  final http.Client _client;
  final String _host;
  final bool _useCache;

  E621CollectionsApi(
    this.headers, {
    http.Client? client,
    String? host,
  })  : _client = client ?? http.Client(),
        _host = host ?? AuthProvider.currentHost,
        _useCache = client == null;

  Future<String?> _get(String path, Map<String, String> params) async {
    final uri = Uri.https(_host, path, params);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _client.get(uri, headers: headers);
        if (response.statusCode == 200) return response.body;
        if ((response.statusCode == 503 || response.statusCode == 429) && attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          continue;
        }
        debugPrint('$_host $path -> ${response.statusCode}');
        return null;
      } catch (e) {
        debugPrint('$_host $path error: $e');
        return null;
      }
    }
    return null;
  }

  String _wildcard(String query) {
    final q = query.trim().replaceAll(RegExp(r'\s+'), '_');
    return q.isEmpty ? '' : '*$q*';
  }

  String _textWildcard(String query) {
    final q = query.trim().replaceAll(RegExp(r'[\s_]+'), '*');
    return q.isEmpty ? '' : '*$q*';
  }

  // ---------------------------------------------------------------- Pools

  static String _resolveApiPoolOrder(String order) {
    if (order == 'fav_count' || order == 'keyword_posts') {
      return 'updated_at';
    }
    return order;
  }

  /// Sorts a list of collections/pools according to [order] and optional [query].
  ///
  /// `fav_count` and `keyword_posts` are always computed locally. `updated_at`,
  /// `post_count` and `name` are re-applied locally too so that results merged
  /// from several requests (name + description + post tags) stay in order.
  static List<E621Collection> sortPools(
    List<E621Collection> pools, {
    required String order,
    String query = '',
    bool keywordSearch = false,
  }) {
    final trimmed = query.trim();
    // Stable sort: ties keep the order the server returned.
    final indexed = [for (var i = 0; i < pools.length; i++) MapEntry(i, pools[i])];

    int Function(MapEntry<int, E621Collection>, MapEntry<int, E621Collection>)? cmp;
    switch (order) {
      case 'fav_count':
        cmp = (x, y) {
          final a = x.value, b = y.value;
          final favCmp = b.totalFavCount.compareTo(a.totalFavCount);
          if (favCmp != 0) return favCmp;
          if (trimmed.isNotEmpty) {
            final kwCmp = b.keywordMatchCount(trimmed).compareTo(a.keywordMatchCount(trimmed));
            if (kwCmp != 0) return kwCmp;
          }
          return b.postCount.compareTo(a.postCount);
        };
      case 'keyword_posts':
        if (trimmed.isNotEmpty) {
          cmp = (x, y) {
            final a = x.value, b = y.value;
            final kwCmp = b.keywordMatchCount(trimmed).compareTo(a.keywordMatchCount(trimmed));
            if (kwCmp != 0) return kwCmp;
            final favCmp = b.totalFavCount.compareTo(a.totalFavCount);
            if (favCmp != 0) return favCmp;
            return b.postCount.compareTo(a.postCount);
          };
        }
      case 'updated_at':
        cmp = (x, y) {
          final a = x.value.updatedAt, b = y.value.updatedAt;
          if (a == null || b == null) return 0;
          return b.compareTo(a);
        };
      case 'created_at':
        cmp = (x, y) {
          final a = x.value.createdAt, b = y.value.createdAt;
          if (a != null && b != null) {
            final c = b.compareTo(a);
            if (c != 0) return c;
          }
          return y.value.id.compareTo(x.value.id);
        };
      case 'post_count':
        cmp = (x, y) => y.value.postCount.compareTo(x.value.postCount);
      case 'name':
        cmp = (x, y) => x.value.displayName
            .toLowerCase()
            .compareTo(y.value.displayName.toLowerCase());
    }

    if (cmp == null) return List<E621Collection>.from(pools);
    final compare = cmp;
    indexed.sort((x, y) {
      final r = compare(x, y);
      return r != 0 ? r : x.key.compareTo(y.key);
    });
    return [for (final e in indexed) e.value];
  }

  /// Searches pools.
  ///
  /// [inName], [inDescription] and [inPosts] choose what [query] is matched
  /// against. When they are omitted, the legacy [keywordSearch] flag (or the
  /// `keyword_posts` order) enables description + post tag matching.
  Future<List<E621Collection>> searchPools({
    String query = '',
    String? category,
    String order = 'updated_at',
    bool keywordSearch = false,
    bool? inName,
    bool? inDescription,
    bool? inPosts,
    String? creatorName,
    bool? isActive,
    int page = 1,
    int limit = 20,
  }) async {
    final trimmed = query.trim();
    final apiOrder = _resolveApiPoolOrder(order);
    final broad = keywordSearch || order == 'keyword_posts';
    final wantName = inName ?? true;
    final wantDesc = inDescription ?? broad;
    final wantPosts = inPosts ?? broad;
    final discoverFavPosts = order == 'fav_count' && (wantName || wantPosts);
    final creator = creatorName?.trim() ?? '';

    Map<String, String> filterParams() => {
          if (category != null) 'search[category]': category,
          if (isActive != null) 'search[is_active]': '$isActive',
          if (creator.isNotEmpty) 'search[creator_name]': creator,
          'search[order]': apiOrder,
          'page': '$page',
          'limit': '$limit',
        };

    if (!discoverFavPosts && (trimmed.isEmpty || (wantName && !wantDesc && !wantPosts))) {
      final body = await _get('/pools.json', {
        if (trimmed.isNotEmpty) 'search[name_matches]': _wildcard(trimmed),
        ...filterParams(),
      });
      if (body == null) return const [];
      final attached = await attachCovers(await compute(_parsePools, body));
      return sortPools(attached, order: order, query: trimmed);
    }

    // Broad search: pool names, pool descriptions, and posts inside pools.
    final poolById = <int, E621Collection>{};
    final matchedPostsByPool = <int, List<E621Post>>{};

    // 1. Pool name match (or base pool list when query is empty)
    if (wantName || trimmed.isEmpty) {
      final nameBody = await _get('/pools.json', {
        if (trimmed.isNotEmpty) 'search[name_matches]': _wildcard(trimmed),
        ...filterParams(),
      });
      if (nameBody != null) {
        for (final p in await compute(_parsePools, nameBody)) {
          poolById[p.id] = p;
        }
      }
    }

    // 2. Pool description match
    if (wantDesc && trimmed.isNotEmpty) {
      final descBody = await _get('/pools.json', {
        'search[description_matches]': _textWildcard(trimmed),
        ...filterParams(),
      });
      if (descBody != null) {
        for (final p in await compute(_parsePools, descBody)) {
          poolById.putIfAbsent(p.id, () => p);
        }
      }
    }

    // 3. Posts inside pools matching the keyword/tags (or top favorited pool posts)
    if ((wantPosts && trimmed.isNotEmpty) || discoverFavPosts) {
      final postTagsQuery = trimmed.isEmpty
          ? 'inpool:true order:favcount'
          : (order == 'fav_count'
              ? '$trimmed inpool:true order:favcount'
              : '$trimmed inpool:true');
      final postsBody = await _get('/posts.json', {
        'tags': postTagsQuery,
        'page': '$page',
        'limit': '60',
      });
      if (postsBody != null) {
        final matchedPosts = _parsePosts(postsBody, requirePreview: false);
        final missingPoolIds = <int>[];
        for (final post in matchedPosts) {
          for (final poolId in post.poolIds) {
            matchedPostsByPool.putIfAbsent(poolId, () => []).add(post);
            if (!poolById.containsKey(poolId) && !missingPoolIds.contains(poolId)) {
              missingPoolIds.add(poolId);
            }
          }
        }
        if (missingPoolIds.isNotEmpty) {
          final fetchedPools = await getPoolsByIds(missingPoolIds.take(limit).toList());
          for (final p in fetchedPools) {
            // These did not go through the server side filters, so apply them here.
            if (category != null && p.category != category) continue;
            if (isActive != null && p.isActive != isActive) continue;
            if (creator.isNotEmpty &&
                (p.creatorName ?? '').toLowerCase() != creator.toLowerCase()) {
              continue;
            }
            poolById.putIfAbsent(p.id, () => p);
          }
        }
      }
    }

    if (poolById.isEmpty) return const [];

    final attached = await attachCovers(poolById.values.toList());

    // Merge any additional matched posts discovered from /posts.json into each pool's posts list
    final merged = attached.map((pool) {
      final extraPosts = matchedPostsByPool[pool.id];
      if (extraPosts == null || extraPosts.isEmpty) return pool;
      final existingIds = pool.posts.map((p) => p.id).toSet();
      final combinedPosts = [
        ...pool.posts,
        for (final p in extraPosts)
          if (!existingIds.contains(p.id)) p,
      ];
      return pool.copyWith(
        posts: combinedPosts,
        serverMatchCount: extraPosts.length,
      );
    }).where((pool) {
      if (trimmed.isEmpty) return true;
      return pool.matchesScope(
        trimmed,
        inName: wantName,
        inDescription: wantDesc,
        inPosts: wantPosts || discoverFavPosts,
      );
    }).toList();

    return sortPools(merged, order: order, query: trimmed, keywordSearch: true);
  }

  Future<List<E621Collection>> getPoolsByIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final byId = <int, E621Collection>{};
    final missing = <int>[];

    for (final id in ids.toSet()) {
      final cached = _useCache ? _poolCache['$_host:$id'] : null;
      if (cached != null) {
        byId[id] = cached;
      } else {
        missing.add(id);
      }
    }

    for (final chunk in _chunks(missing)) {
      final body = await _get('/pools.json', {
        'search[id]': chunk.join(','),
        'limit': '${chunk.length}',
      });
      if (body == null) continue;
      final parsed = (!_useCache || body.length < 32768)
          ? _parsePools(body)
          : await compute(_parsePools, body);
      for (final pool in parsed) {
        if (_useCache) {
          if (_poolCache.length > 500) _poolCache.clear();
          _poolCache['$_host:${pool.id}'] = pool;
        }
        byId[pool.id] = pool;
      }
    }

    return [
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!,
    ];
  }

  Future<E621Collection?> getPool(int id) async {
    final list = await getPoolsByIds([id]);
    return list.isEmpty ? null : list.first;
  }

  // ----------------------------------------------------------------- Sets

  Future<List<E621Collection>> searchSets({
    String query = '',
    String? creatorName,
    String order = 'updated_at',
    bool keywordSearch = false,
    bool? inName,
    bool? inDescription,
    bool? inPosts,
    int page = 1,
    int limit = 20,
  }) async {
    final trimmed = query.trim();
    final broad = keywordSearch || order == 'keyword_posts';
    final wantName = inName ?? true;
    final wantDesc = inDescription ?? broad;
    final wantPosts = inPosts ?? broad;
    final apiOrder = order == 'fav_count' ? 'post_count' : _resolveApiPoolOrder(order);
    final setById = <int, E621Collection>{};
    final creator = creatorName?.trim();

    final positiveTokens = trimmed
        .split(RegExp(r'\s+'))
        .where((t) =>
            t.isNotEmpty &&
            !t.startsWith('-') &&
            !t.startsWith('~') &&
            !t.contains(':'))
        .toList();
    final nameQuery = (wantPosts && positiveTokens.isNotEmpty)
        ? positiveTokens.join(' ')
        : trimmed;

    // 1. Set name match (or default listing when query is empty)
    if (wantName || trimmed.isEmpty || (wantPosts && positiveTokens.isNotEmpty)) {
      final body = await _get('/post_sets.json', {
        if (nameQuery.isNotEmpty) 'search[name]': _textWildcard(nameQuery),
        if (creator != null && creator.isNotEmpty) 'search[creator_name]': creator,
        'search[order]': apiOrder,
        'page': '$page',
        'limit': '$limit',
      });
      if (body != null) {
        for (final s in await compute(_parseSets, body)) {
          setById[s.id] = s;
        }
      }
    }

    // 2. Broader candidate sets when searching descriptions or post tags
    if ((wantDesc || wantPosts) && trimmed.isNotEmpty) {
      final extraBody = await _get('/post_sets.json', {
        if (wantDesc && !wantPosts) 'search[description]': _textWildcard(trimmed),
        if (creator != null && creator.isNotEmpty) 'search[creator_name]': creator,
        'search[order]': apiOrder,
        'page': '$page',
        'limit': '$limit',
      });
      if (extraBody != null) {
        for (final s in await compute(_parseSets, extraBody)) {
          setById.putIfAbsent(s.id, () => s);
        }
      }
    }

    if (setById.isEmpty) return const [];
    final attached = await attachCovers(setById.values.toList());

    // 3. Server-side post tag evaluation for candidate sets' posts
    final matchedPostsBySet = <int, List<E621Post>>{};
    if (wantPosts && trimmed.isNotEmpty) {
      final postToSetIds = <int, List<int>>{};
      for (final s in attached) {
        for (final postId in s.postIds) {
          postToSetIds.putIfAbsent(postId, () => []).add(s.id);
        }
      }
      final candidatePostIds = postToSetIds.keys.take(_maxIdsPerQuery).toList();
      if (candidatePostIds.isNotEmpty) {
        final postTagsQuery = order == 'fav_count'
            ? 'id:${candidatePostIds.join(",")} $trimmed order:favcount'
            : 'id:${candidatePostIds.join(",")} $trimmed';
        final postsBody = await _get('/posts.json', {
          'tags': postTagsQuery,
          'limit': '${candidatePostIds.length}',
        });
        if (postsBody != null) {
          for (final post in _parsePosts(postsBody, requirePreview: false)) {
            final setIds = postToSetIds[post.id];
            if (setIds != null) {
              for (final setId in setIds) {
                matchedPostsBySet.putIfAbsent(setId, () => []).add(post);
              }
            }
          }
        }
      }
    }

    final merged = attached.map((s) {
      final extraPosts = matchedPostsBySet[s.id];
      if (extraPosts == null || extraPosts.isEmpty) return s;
      final existingIds = s.posts.map((p) => p.id).toSet();
      final combinedPosts = [
        ...s.posts,
        for (final p in extraPosts)
          if (!existingIds.contains(p.id)) p,
      ];
      return s.copyWith(
        posts: combinedPosts,
        serverMatchCount: extraPosts.length,
      );
    }).where((s) {
      if (trimmed.isEmpty) return true;
      if (!wantDesc && !wantPosts && wantName) return true;
      return s.matchesScope(
        trimmed,
        inName: wantName,
        inDescription: wantDesc,
        inPosts: wantPosts,
      );
    }).toList();

    return sortPools(
      merged,
      order: order,
      query: trimmed,
      keywordSearch: broad || wantDesc || wantPosts,
    );
  }

  Future<List<E621Collection>> getSetsByIds(List<int> ids) async {
    final result = <E621Collection>[];
    for (final chunk in _chunks(ids)) {
      final body = await _get('/post_sets.json', {
        'search[id]': chunk.join(','),
        'limit': '${chunk.length}',
      });
      if (body != null) result.addAll(await compute(_parseSets, body));
    }
    return result;
  }

  Future<E621Collection?> getSet(int id) async {
    final list = await getSetsByIds([id]);
    return list.isEmpty ? null : list.first;
  }

  // ---------------------------------------------------------------- Posts

  /// Fetches posts by id (in batches of 100). Order is NOT preserved.
  Future<Map<int, E621Post>> getPostsByIds(
    List<int> ids, {
    bool requirePreview = true,
  }) async {
    final result = <int, E621Post>{};
    final isSafeMode = _host == 'e926.net';
    final missing = <int>[];

    for (final id in ids.toSet()) {
      final cached = _useCache ? _postCache['$_host:$id'] : null;
      if (cached != null) {
        if (!requirePreview ||
            (cached.previewUrl != null && (!isSafeMode || cached.rating.toLowerCase() == 's'))) {
          result[id] = cached;
        }
      } else {
        missing.add(id);
      }
    }

    for (final chunk in _chunks(missing)) {
      final body = await _get('/posts.json', {
        'tags': 'id:${chunk.join(',')} status:any',
        'limit': '${chunk.length}',
      });
      if (body == null) continue;
      for (final post in _parsePosts(body, requirePreview: false)) {
        if (_useCache) {
          if (_postCache.length > 2000) _postCache.clear();
          _postCache['$_host:${post.id}'] = post;
        }
        if (!requirePreview ||
            (post.previewUrl != null && (!isSafeMode || post.rating.toLowerCase() == 's'))) {
          result[post.id] = post;
        }
      }
    }
    return result;
  }

  /// Fetches posts keeping the order of [ids] (used for pool reading order).
  /// Deleted/hidden posts are skipped.
  Future<List<E621Post>> getPostsInOrder(List<int> ids) async {
    final map = await getPostsByIds(ids);
    return ids.map((id) => map[id]).whereType<E621Post>().toList();
  }

  /// Posts of a set, newest first.
  Future<List<E621Post>> getSetPosts(String shortname, {int page = 1, int limit = 60}) async {
    final body = await _get('/posts.json', {
      'tags': 'set:$shortname',
      'page': '$page',
      'limit': '$limit',
    });
    return body == null ? const [] : _parsePosts(body);
  }

  /// Resolves cover images and collection posts for a page of collections with
  /// batched `posts.json?tags=id:...` requests instead of one request per card.
  Future<List<E621Collection>> attachCovers(List<E621Collection> collections) async {
    final ids = <int>{};
    // Always prioritize coverPostId first so covers fit in the first batch.
    for (final c in collections) {
      if (c.coverPostId != null) {
        ids.add(c.coverPostId!);
      }
    }
    for (final c in collections) {
      if (c.postIds.isNotEmpty) {
        ids.addAll(c.postIds.take(_maxPoolPostsToInspect));
      }
    }
    if (ids.isEmpty) return collections;
    final posts = await getPostsByIds(ids.toList(), requirePreview: false);
    final isSafeMode = _host == 'e926.net';

    if (isSafeMode) {
      final extraIds = <int>{};
      for (final c in collections) {
        if (c.postIds.length <= _maxPoolPostsToInspect) continue;
        final hasSafeInInitial = [
          if (c.coverPostId != null) c.coverPostId!,
          ...c.postIds.take(_maxPoolPostsToInspect),
        ].any((id) {
          final p = posts[id];
          return p != null && p.previewUrl != null && p.rating.toLowerCase() == 's';
        });
        if (!hasSafeInInitial) {
          extraIds.addAll(c.postIds.skip(_maxPoolPostsToInspect).take(15));
        }
      }
      if (extraIds.isNotEmpty) {
        posts.addAll(await getPostsByIds(extraIds.toList(), requirePreview: false));
      }
    }

    return collections.map((c) {
      final coverPost = c.coverPostId != null ? posts[c.coverPostId] : null;
      final resolvedPosts = c.postIds
          .map((id) => posts[id])
          .whereType<E621Post>()
          .toList();
      if (coverPost != null && !resolvedPosts.any((p) => p.id == coverPost.id)) {
        resolvedPosts.insert(0, coverPost);
      }

      String? validCoverUrl = (coverPost?.previewUrl != null &&
              (!isSafeMode || coverPost!.rating.toLowerCase() == 's'))
          ? coverPost?.previewUrl
          : c.coverUrl;
      if (validCoverUrl == null) {
        for (final p in resolvedPosts) {
          if (p.previewUrl != null && (!isSafeMode || p.rating.toLowerCase() == 's')) {
            validCoverUrl = p.previewUrl;
            break;
          }
        }
      }

      return c.copyWith(
        coverUrl: validCoverUrl,
        posts: resolvedPosts.isNotEmpty ? resolvedPosts : c.posts,
      );
    }).toList();
  }

  // -------------------------------------------------------------- Helpers

  List<E621Post> _parsePosts(String body, {bool requirePreview = true}) {
    final dynamic data = jsonDecode(body);
    final List<dynamic> list = (data is List)
        ? data
        : (data is Map && data['posts'] is List ? data['posts'] as List<dynamic> : const []);
    final isSafeMode = _host == 'e926.net';
    return list
        .whereType<Map<String, dynamic>>()
        .map(E621Post.fromJson)
        .where((p) =>
            !requirePreview ||
            (p.previewUrl != null && (!isSafeMode || p.rating.toLowerCase() == 's')))
        .toList();
  }

  Iterable<List<int>> _chunks(List<int> ids) sync* {
    for (var i = 0; i < ids.length; i += _maxIdsPerQuery) {
      yield ids.sublist(i, (i + _maxIdsPerQuery).clamp(0, ids.length));
    }
  }
}
