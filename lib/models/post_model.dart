class E621Post {
  final int id;
  final String? previewUrl;
  final String? fileUrl;
  final String extension;
  final List<String> artistTags;
  final List<String> characterTags;
  final List<String> speciesTags;
  final List<String> copyrightTags;
  final List<String> generalTags;
  final int score;
  final int favCount;
  final String rating;
  final String description;
  final bool isFavorited;
  final List<int> poolIds;
  final int? parentId;
  final List<int> childrenIds;

  E621Post({
    required this.id,
    this.previewUrl,
    this.fileUrl,
    required this.extension,
    required this.artistTags,
    required this.characterTags,
    required this.speciesTags,
    required this.copyrightTags,
    required this.generalTags,
    this.score = 0,
    this.favCount = 0,
    this.rating = '',
    this.description = '',
    this.isFavorited = false,
    this.poolIds = const [],
    this.parentId,
    this.childrenIds = const [],
  });

  bool get hasPools => poolIds.isNotEmpty;
  bool get hasParent => parentId != null;
  bool get hasChildren => childrenIds.isNotEmpty;
  bool get hasRelationships => hasParent || hasChildren;

  static int? _parsePositiveInt(dynamic raw) {
    if (raw == null) return null;
    final val = raw is num ? raw.toInt() : int.tryParse(raw.toString());
    return (val != null && val > 0) ? val : null;
  }

  static List<int> _parsePositiveIntList(dynamic raw) {
    if (raw is List) {
      return raw
          .map(_parsePositiveInt)
          .whereType<int>()
          .toList();
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return raw
          .trim()
          .split(RegExp(r'[\s,]+'))
          .map(_parsePositiveInt)
          .whereType<int>()
          .toList();
    }
    return const [];
  }

  Set<String>? _cachedAllTags;

  /// Returns a cached set of all lowercase tags across all categories for fast lookups.
  Set<String> get allTags {
    if (_cachedAllTags != null) return _cachedAllTags!;
    final set = <String>{};
    for (final t in artistTags) {
      set.add(t.toLowerCase());
    }
    for (final t in characterTags) {
      set.add(t.toLowerCase());
    }
    for (final t in speciesTags) {
      set.add(t.toLowerCase());
    }
    for (final t in copyrightTags) {
      set.add(t.toLowerCase());
    }
    for (final t in generalTags) {
      set.add(t.toLowerCase());
    }
    _cachedAllTags = set;
    return set;
  }

  factory E621Post.fromJson(Map<String, dynamic> json) {
    // 1. Files & URLs (Support both v2 'files' object and legacy v1 'file', 'sample', 'preview')
    String? fileUrl;
    String? previewUrl;
    String ext = '';
    String? md5;

    final bool isDeleted = (json['flags'] is Map && json['flags']['deleted'] == true) ||
        (json['files'] is Map &&
            json['files']['flags'] is Map &&
            json['files']['flags']['deleted'] == true);

    if (json['files'] is Map) {
      final files = json['files'] as Map<String, dynamic>;

      // Meta (ext, size, md5, etc.)
      final meta = files['meta'] as Map<String, dynamic>?;
      if (meta != null) {
        if (meta['ext'] != null) {
          ext = meta['ext'].toString();
        }
        if (meta['md5'] != null) {
          md5 = meta['md5'].toString();
        }
      }

      // Original file
      final original = files['original'] as Map<String, dynamic>?;
      if (original != null && original['url'] != null) {
        fileUrl = original['url'] as String?;
      }

      // Sample & Preview URLs (v2 provides jpg and webp variants)
      final sample = files['sample'] as Map<String, dynamic>?;
      final preview = files['preview'] as Map<String, dynamic>?;

      previewUrl = sample?['jpg'] as String? ??
          sample?['webp'] as String? ??
          preview?['jpg'] as String? ??
          preview?['webp'] as String?;
    }

    // Fallback to legacy v1 structure if fields were not extracted from v2 'files'
    if (json['file'] is Map) {
      fileUrl ??= json['file']['url'] as String?;
      if (ext.isEmpty && json['file']['ext'] != null) {
        ext = json['file']['ext'].toString();
      }
      md5 ??= json['file']['md5']?.toString();
    }

    previewUrl ??= (json['sample'] is Map ? json['sample']['url'] as String? : null) ??
        (json['preview'] is Map ? json['preview']['url'] as String? : null);

    // Reconstruct CDN URLs from md5 + ext when e621's server-side global filter
    // sets url fields to null on non-deleted posts.
    if (!isDeleted && md5 != null && md5.length >= 4) {
      final sub = '${md5.substring(0, 2)}/${md5.substring(2, 4)}/$md5';
      if (fileUrl == null && ext.isNotEmpty) {
        fileUrl = 'https://static1.e621.net/data/$sub.$ext';
      }
      if (previewUrl == null) {
        final hasSample = json['sample'] is Map && json['sample']['has'] == true;
        final isVideoOrFlash = ext == 'webm' || ext == 'mp4' || ext == 'swf';
        if (hasSample && !isVideoOrFlash) {
          previewUrl = 'https://static1.e621.net/data/sample/$sub.jpg';
        } else {
          previewUrl = 'https://static1.e621.net/data/preview/$sub.jpg';
        }
      }
    }

    // Fallback previewUrl to fileUrl for static images
    if (previewUrl == null &&
        fileUrl != null &&
        ext != 'webm' &&
        ext != 'mp4' &&
        ext != 'swf') {
      previewUrl = fileUrl;
    }

    // Additional fallback for extension if missing
    if (ext.isEmpty && fileUrl != null) {
      final uri = Uri.tryParse(fileUrl);
      if (uri != null && uri.pathSegments.isNotEmpty) {
        final filename = uri.pathSegments.last;
        final dotIndex = filename.lastIndexOf('.');
        if (dotIndex != -1 && dotIndex < filename.length - 1) {
          ext = filename.substring(dotIndex + 1);
        }
      }
    }

    // 2. Tags (Support v2 mode=extended Map, v2 mode=basic flat List, and legacy v1 Map)
    List<String> artistTags = [];
    List<String> characterTags = [];
    List<String> speciesTags = [];
    List<String> copyrightTags = [];
    List<String> generalTags = [];

    final rawTags = json['tags'];
    if (rawTags is Map) {
      artistTags = List<String>.from(rawTags['artist'] ?? []);
      characterTags = List<String>.from(rawTags['character'] ?? []);
      speciesTags = List<String>.from(rawTags['species'] ?? []);
      copyrightTags = List<String>.from(rawTags['copyright'] ?? []);
      generalTags = [
        ...List<String>.from(rawTags['general'] ?? []),
        ...List<String>.from(rawTags['meta'] ?? []),
        ...List<String>.from(rawTags['lore'] ?? []),
      ];
    } else if (rawTags is List) {
      // In v2 mode=basic or thumbnails, tags are a flat array
      generalTags = rawTags.map((e) => e.toString()).toList();
    }

    // 3. Stats (Support v2 'stats' object and legacy v1 root fields)
    int score = 0;
    int favCount = 0;
    bool isFavorited = false;

    if (json['stats'] is Map) {
      final stats = json['stats'] as Map<String, dynamic>;
      final scoreVal = stats['score'];
      if (scoreVal is Map) {
        score = (scoreVal['total'] as num?)?.toInt() ?? 0;
      } else if (scoreVal is num) {
        score = scoreVal.toInt();
      }
      favCount = (stats['fav_count'] as num?)?.toInt() ?? 0;
      isFavorited = stats['is_favorited'] == true;
    } else {
      final scoreVal = json['score'];
      if (scoreVal is Map) {
        score = (scoreVal['total'] as num?)?.toInt() ?? 0;
      } else if (scoreVal is num) {
        score = scoreVal.toInt();
      }
      favCount = (json['fav_count'] as num?)?.toInt() ?? 0;
      isFavorited = json['is_favorited'] == true;
    }

    final rating = json['rating']?.toString() ?? '';
    final description = json['description']?.toString() ?? '';
    final List<int> poolIds = _parsePositiveIntList(json['pools'] ?? json['poolIds']);

    int? parentId;
    List<int> childrenIds = const [];
    final rel = json['relationships'];
    if (rel is Map) {
      parentId = _parsePositiveInt(rel['parent_id'] ?? rel['parentId']);
      childrenIds = _parsePositiveIntList(
        rel['children'] ?? rel['children_ids'] ?? rel['childrenIds'],
      );
    } else {
      parentId = _parsePositiveInt(json['parent_id'] ?? json['parentId']);
      childrenIds = _parsePositiveIntList(
        json['children'] ?? json['children_ids'] ?? json['childrenIds'],
      );
    }

    return E621Post(
      id: (json['id'] as num?)?.toInt() ?? 0,
      previewUrl: previewUrl,
      fileUrl: fileUrl,
      extension: ext,
      artistTags: artistTags,
      characterTags: characterTags,
      speciesTags: speciesTags,
      copyrightTags: copyrightTags,
      generalTags: generalTags,
      score: score,
      favCount: favCount,
      rating: rating,
      description: description,
      isFavorited: isFavorited,
      poolIds: poolIds,
      parentId: parentId,
      childrenIds: childrenIds,
    );
  }

  /// Checks whether this post matches all tokens in a keyword/tag [query].
  /// Returns `false` if [query] is empty.
  bool matchesKeywordQuery(String query) {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return false;
    final tokens = trimmed.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    if (tokens.isEmpty) return false;
    return tokens.every(matchesKeywordToken);
  }

  /// Checks whether this post matches a single keyword/tag [token].
  bool matchesKeywordToken(String token) {
    final lower = token.trim().toLowerCase();
    if (lower.isEmpty) return true;
    if ((lower.startsWith('-') || lower.startsWith('~')) && lower.length > 1) {
      return !_matchesPositiveKeywordToken(lower.substring(1));
    }
    return _matchesPositiveKeywordToken(lower);
  }

  bool _matchesPositiveKeywordToken(String lower) {
    final norm = lower.replaceAll(' ', '_');
    final spaced = lower.replaceAll('_', ' ');
    final tags = allTags;

    if (norm.startsWith('rating:')) {
      final r = norm.substring(7).trim();
      final postRating = rating.toLowerCase();
      if (r == 's' || r == 'safe') return postRating == 's' || postRating == 'safe';
      if (r == 'q' || r == 'questionable') return postRating == 'q' || postRating == 'questionable';
      if (r == 'e' || r == 'explicit') return postRating == 'e' || postRating == 'explicit';
      return postRating == r;
    }

    if (norm.contains('*')) {
      final escaped = RegExp.escape(norm).replaceAll(r'\*', '.*');
      final regex = RegExp('^$escaped\$');
      if (tags.any((t) => regex.hasMatch(t))) return true;
    } else {
      if (tags.contains(norm) || tags.any((t) => t.contains(norm))) {
        return true;
      }
    }

    if (description.isNotEmpty) {
      final descLower = description.toLowerCase();
      if (descLower.contains(spaced) || descLower.contains(norm)) {
        return true;
      }
    }

    return false;
  }

  // --- Local Serialization for Guest Mode ---
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'previewUrl': previewUrl,
      'fileUrl': fileUrl,
      'extension': extension,
      'artistTags': artistTags,
      'characterTags': characterTags,
      'speciesTags': speciesTags,
      'copyrightTags': copyrightTags,
      'generalTags': generalTags,
      'score': score,
      'favCount': favCount,
      'rating': rating,
      'description': description,
      'isFavorited': isFavorited,
      'poolIds': poolIds,
      'parentId': parentId,
      'childrenIds': childrenIds,
    };
  }

  factory E621Post.fromLocalJson(Map<String, dynamic> json) {
    return E621Post(
      id: (json['id'] as num?)?.toInt() ?? 0,
      previewUrl: json['previewUrl'] as String?,
      fileUrl: json['fileUrl'] as String?,
      extension: json['extension']?.toString() ?? '',
      artistTags: List<String>.from(json['artistTags'] ?? []),
      characterTags: List<String>.from(json['characterTags'] ?? []),
      speciesTags: List<String>.from(json['speciesTags'] ?? []),
      copyrightTags: List<String>.from(json['copyrightTags'] ?? []),
      generalTags: List<String>.from(json['generalTags'] ?? []),
      score: (json['score'] as num?)?.toInt() ?? 0,
      favCount: (json['favCount'] as num?)?.toInt() ?? 0,
      rating: json['rating']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      isFavorited: json['isFavorited'] == true,
      poolIds: _parsePositiveIntList(json['poolIds'] ?? json['pools']),
      parentId: _parsePositiveInt(json['parentId'] ?? json['parent_id']),
      childrenIds: _parsePositiveIntList(json['childrenIds'] ?? json['children']),
    );
  }
}