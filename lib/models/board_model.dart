import 'post_model.dart';

class Board {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<int> postIds;
  final List<E621Post> posts;

  Board({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.postIds,
    required this.posts,
  });

  int get postCount => postIds.length;

  String? get coverUrl => posts.isNotEmpty ? posts.first.previewUrl : null;

  Board copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    List<int>? postIds,
    List<E621Post>? posts,
  }) {
    return Board(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      postIds: postIds ?? this.postIds,
      posts: posts ?? this.posts,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'postIds': postIds,
      'posts': posts.map((p) => p.toJson()).toList(),
    };
  }

  factory Board.fromJson(Map<String, dynamic> json) {
    final rawPostIds = json['postIds'] as List<dynamic>? ?? [];
    final postIds = rawPostIds.map((e) => (e as num).toInt()).toList();

    final rawPosts = json['posts'] as List<dynamic>? ?? [];
    final posts = rawPosts
        .whereType<Map<String, dynamic>>()
        .map((e) => E621Post.fromLocalJson(e))
        .toList();

    DateTime parsedDate = DateTime.now();
    if (json['createdAt'] != null) {
      final tryDate = DateTime.tryParse(json['createdAt'].toString());
      if (tryDate != null) parsedDate = tryDate;
    }

    return Board(
      id: json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'Untitled Board',
      createdAt: parsedDate,
      postIds: postIds,
      posts: posts,
    );
  }
}
