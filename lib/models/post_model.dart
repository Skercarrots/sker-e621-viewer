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
  });

  factory E621Post.fromJson(Map<String, dynamic> json) {
    // 1. Files & URLs (Support both v2 'files' object and legacy v1 'file', 'sample', 'preview')
    String? fileUrl;
    String? previewUrl;
    String ext = '';

    if (json['files'] is Map) {
      final files = json['files'] as Map<String, dynamic>;

      // Meta (ext, size, md5, etc.)
      final meta = files['meta'] as Map<String, dynamic>?;
      if (meta != null && meta['ext'] != null) {
        ext = meta['ext'].toString();
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
          preview?['webp'] as String? ??
          fileUrl;
    }

    // Fallback to legacy v1 structure if fields were not extracted from v2 'files'
    fileUrl ??= json['file']?['url'] as String?;
    if (ext.isEmpty) {
      ext = json['file']?['ext']?.toString() ?? '';
    }
    previewUrl ??= json['sample']?['url'] as String? ??
        json['preview']?['url'] as String? ??
        fileUrl;

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
      generalTags = List<String>.from(rawTags['general'] ?? []);
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
    );
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
    );
  }
}