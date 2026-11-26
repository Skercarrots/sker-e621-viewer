import 'package:flutter/material.dart';

/// Represents a single user-favorited e621 tag with its category metadata.
class FavoriteTag {
  final String name;
  final int category;
  final DateTime createdAt;

  const FavoriteTag({
    required this.name,
    this.category = 0,
    required this.createdAt,
  });

  static const List<String> _filterPrefixes = [
    'order:',
    'rating:',
    'score:',
    'favcount:',
    'type:',
    'status:',
    'date:',
    'id:',
    'pool:',
    'set:',
    'fav:',
    'user:',
    'parent:',
    'filesize:',
    'width:',
    'height:',
    'duration:',
  ];

  /// Normalizes a raw tag string to trimmed lowercase.
  static String normalizeName(String raw) => raw.trim().toLowerCase();

  /// Infers an e621 category code when none is explicitly known.
  static int inferCategory(String rawName, {int fallback = 0}) {
    final normalized = normalizeName(rawName);
    if (normalized.isEmpty) return fallback;
    final body = (normalized.startsWith('-') || normalized.startsWith('~'))
        ? normalized.substring(1)
        : normalized;
    for (final prefix in _filterPrefixes) {
      if (body.startsWith(prefix)) {
        return -1;
      }
    }
    return fallback;
  }

  /// Category color matching tag chips in `PostDetailPage` and `TagSuggestion`.
  static Color colorForCategory(int category) {
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

  /// Human-readable category label matching e621 tag categories.
  static String labelForCategory(int category) {
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

  Color get categoryColor => colorForCategory(category);

  String get categoryLabel => labelForCategory(category);

  FavoriteTag copyWith({
    String? name,
    int? category,
    DateTime? createdAt,
  }) {
    return FavoriteTag(
      name: name ?? this.name,
      category: category ?? this.category,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category,
        'created_at': createdAt.toIso8601String(),
      };

  factory FavoriteTag.fromJson(Map<String, dynamic> json) {
    final name = normalizeName((json['name'] as String?) ?? '');
    final rawCategory = (json['category'] as num?)?.toInt();
    final createdAtRaw = json['created_at'] as String?;
    return FavoriteTag(
      name: name,
      category: rawCategory ?? inferCategory(name),
      createdAt: (createdAtRaw != null ? DateTime.tryParse(createdAtRaw) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Represents a named local collection of favorite tags.
class FavoriteTagSet {
  final String id;
  final String name;
  final List<String> tagNames;
  final DateTime createdAt;

  const FavoriteTagSet({
    required this.id,
    required this.name,
    required this.tagNames,
    required this.createdAt,
  });

  int get tagCount => tagNames.length;

  FavoriteTagSet copyWith({
    String? id,
    String? name,
    List<String>? tagNames,
    DateTime? createdAt,
  }) {
    return FavoriteTagSet(
      id: id ?? this.id,
      name: name ?? this.name,
      tagNames: tagNames ?? this.tagNames,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tag_names': tagNames,
        'created_at': createdAt.toIso8601String(),
      };

  factory FavoriteTagSet.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tag_names'];
    final List<String> parsedTags = [];
    final Set<String> seen = {};
    if (rawTags is List) {
      for (final item in rawTags) {
        if (item is String) {
          final normalized = FavoriteTag.normalizeName(item);
          if (normalized.isNotEmpty && seen.add(normalized)) {
            parsedTags.add(normalized);
          }
        }
      }
    }
    final createdAtRaw = json['created_at'] as String?;
    return FavoriteTagSet(
      id: (json['id'] as String?) ?? '',
      name: ((json['name'] as String?) ?? '').trim(),
      tagNames: parsedTags,
      createdAt: (createdAtRaw != null ? DateTime.tryParse(createdAtRaw) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
