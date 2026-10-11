import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'post_model.dart';

class E621User {
  final int id;
  final String name;
  final String levelString;
  final int? avatarId; // avatar_id can be null in the API
  final int postCount;
  final int favoriteCount;

  // This will store the resolved URL after we fetch post data
  String? resolvedAvatarUrl;

  E621User({
    required this.id,
    required this.name,
    required this.levelString,
    this.avatarId,
    required this.postCount,
    required this.favoriteCount,
    this.resolvedAvatarUrl,
  });

  factory E621User.fromJson(Map<String, dynamic> json) {
    return E621User(
      id: json['id'] ?? 0,
      name: json['name'] ?? 'Unknown',
      levelString: json['level_string'] ?? 'Member',
      avatarId: json['avatar_id'],
      postCount: json['post_count'] ?? 0,
      favoriteCount: json['favorite_count'] ?? 0,
      resolvedAvatarUrl: json['resolved_avatar_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'level_string': levelString,
      'avatar_id': avatarId,
      'post_count': postCount,
      'favorite_count': favoriteCount,
      'resolved_avatar_url': resolvedAvatarUrl,
    };
  }

  /// Returns the avatar URL. 
  /// Requires [resolvedAvatarUrl] to be populated by the fetcher.
  String get avatarUrl {
    if (avatarId == null || avatarId == 0) {
      return "https://e621.net/images/user-avatar.png";
    }
    return resolvedAvatarUrl ?? "https://e621.net/images/user-avatar.png";
  }
}

class E621ApiService {
  static const String baseUrl = "https://e621.net";
  static const String userAgent = "SkerE621/1.0 (by anonymous on e621)";

  /// Fetches user data by username
  Future<E621User?> fetchUser(String username) async {
    final response = await http.get(
      Uri.parse('$baseUrl/users/$username.json'),
      headers: {'User-Agent': userAgent},
    );

    if (response.statusCode == 200) {
      final user = E621User.fromJson(jsonDecode(response.body));
      
      // If the user has an avatar, we must resolve its real URL
      if (user.avatarId != null) {
        user.resolvedAvatarUrl = await _resolvePostThumbnail(user.avatarId!);
      }
      
      return user;
    }
    return null;
  }

  /// Fetches the post metadata to get the preview URL
  Future<String?> _resolvePostThumbnail(int postId) async {
    try {
      final uri = Uri.parse('$baseUrl/posts/$postId.json?v2=true');
      final response = await http.get(
        uri,
        headers: {'User-Agent': userAgent},
      );

      if (response.statusCode == 200) {
        final dynamic postData = jsonDecode(response.body);
        final Map<String, dynamic>? postMap = (postData is Map<String, dynamic>)
            ? (postData['post'] is Map<String, dynamic>
                ? postData['post'] as Map<String, dynamic>
                : postData)
            : null;

        if (postMap != null) {
          final post = E621Post.fromJson(postMap);
          return post.previewUrl;
        }
      }
    } catch (e) {
      debugPrint("Error resolving avatar: $e");
    }
    return null;
  }
}