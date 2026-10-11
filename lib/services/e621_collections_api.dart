import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/collection_model.dart';
import '../models/post_model.dart';

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

/// Sort options available for each collection type.
class CollectionOrder {
  final String value;
  final String label;
  const CollectionOrder(this.value, this.label);

  static const pools = [
    CollectionOrder('updated_at', 'Recently updated'),
    CollectionOrder('created_at', 'Newest'),
    CollectionOrder('post_count', 'Most posts'),
    CollectionOrder('name', 'Name'),
  ];

  // `post_count` is left out on purpose: the biggest sets have huge payloads.
  static const sets = [
    CollectionOrder('updated_at', 'Recently updated'),
    CollectionOrder('created_at', 'Newest'),
    CollectionOrder('name', 'Name'),
  ];
}

/// Thin client for e621 pools / post sets endpoints.
class E621CollectionsApi {
  static const _host = 'e621.net';
  static const _maxIdsPerQuery = 100;

  final Map<String, String> headers;
  final http.Client _client;

  E621CollectionsApi(this.headers, {http.Client? client}) : _client = client ?? http.Client();

  Future<String?> _get(String path, Map<String, String> params) async {
    final uri = Uri.https(_host, path, params);
    try {
      final response = await _client.get(uri, headers: headers);
      if (response.statusCode == 200) return response.body;
      debugPrint('e621 $path -> ${response.statusCode}');
    } catch (e) {
      debugPrint('e621 $path error: $e');
    }
    return null;
  }

  String _wildcard(String query) {
    final q = query.trim().replaceAll(' ', '_');
    return q.isEmpty ? '' : '*$q*';
  }

  // ---------------------------------------------------------------- Pools

  Future<List<E621Collection>> searchPools({
    String query = '',
    String? category,
    String order = 'updated_at',
    int page = 1,
    int limit = 20,
  }) async {
    final body = await _get('/pools.json', {
      if (query.trim().isNotEmpty) 'search[name_matches]': _wildcard(query),
      if (category != null) 'search[category]': category,
      'search[order]': order,
      'page': '$page',
      'limit': '$limit',
    });
    if (body == null) return const [];
    return attachCovers(await compute(_parsePools, body));
  }

  Future<List<E621Collection>> getPoolsByIds(List<int> ids) async {
    final result = <E621Collection>[];
    for (final chunk in _chunks(ids)) {
      final body = await _get('/pools.json', {
        'search[id]': chunk.join(','),
        'limit': '${chunk.length}',
      });
      if (body != null) result.addAll(await compute(_parsePools, body));
    }
    return result;
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
    int page = 1,
    int limit = 20,
  }) async {
    final body = await _get('/post_sets.json', {
      if (query.trim().isNotEmpty) 'search[name]': _wildcard(query),
      if (creatorName != null) 'search[creator_name]': creatorName,
      'search[order]': order,
      'page': '$page',
      'limit': '$limit',
    });
    if (body == null) return const [];
    return attachCovers(await compute(_parseSets, body));
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
  Future<Map<int, E621Post>> getPostsByIds(List<int> ids) async {
    final result = <int, E621Post>{};
    for (final chunk in _chunks(ids.toSet().toList())) {
      final body = await _get('/posts.json', {
        'tags': 'id:${chunk.join(',')}',
        'limit': '${chunk.length}',
      });
      if (body == null) continue;
      for (final post in _parsePosts(body)) {
        result[post.id] = post;
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

  /// Resolves cover images for a page of collections with a single
  /// `posts.json?tags=id:...` request instead of one request per card.
  Future<List<E621Collection>> attachCovers(List<E621Collection> collections) async {
    final ids = collections
        .where((c) => c.coverUrl == null && c.coverPostId != null)
        .map((c) => c.coverPostId!)
        .toList();
    if (ids.isEmpty) return collections;
    final posts = await getPostsByIds(ids);
    return collections.map((c) {
      final post = posts[c.coverPostId];
      return post?.previewUrl != null ? c.copyWith(coverUrl: post!.previewUrl) : c;
    }).toList();
  }

  // -------------------------------------------------------------- Helpers

  List<E621Post> _parsePosts(String body) {
    final dynamic data = jsonDecode(body);
    final List<dynamic> list = (data is List)
        ? data
        : (data is Map && data['posts'] is List ? data['posts'] as List<dynamic> : const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(E621Post.fromJson)
        .where((p) => p.previewUrl != null)
        .toList();
  }

  Iterable<List<int>> _chunks(List<int> ids) sync* {
    for (var i = 0; i < ids.length; i += _maxIdsPerQuery) {
      yield ids.sublist(i, (i + _maxIdsPerQuery).clamp(0, ids.length));
    }
  }
}

