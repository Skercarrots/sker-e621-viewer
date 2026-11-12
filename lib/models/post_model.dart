class E621Post {
  final int id;
  final String? previewUrl;
  final String? fileUrl;
  final String extension;
  final List<String> videoVariants;
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
    this.videoVariants = const [],
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

  bool get isVideo {
    final ext = extension.toLowerCase();
    return ext == 'webm' || ext == 'mp4';
  }

  /// Ordered list of candidate video URLs to try for playback.
  /// Prefers hardware-friendly variants (e.g. MP4 / 720p / 480p samples) when
  /// available, followed by the original [fileUrl], and deterministic CDN
  /// sample fallbacks if the primary stream fails to decode.
  List<String> get playableVideoUrls {
    final seen = <String>{};
    final result = <String>[];

    void addUrl(String? raw) {
      if (raw == null) return;
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return;
      final lower = trimmed.toLowerCase();
      if (lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif') ||
          lower.endsWith('.swf')) {
        return;
      }
      if (seen.add(trimmed)) {
        result.add(trimmed);
      }
    }

    // 1. Variants are stored pre-ranked (see _collectRankedAlternates):
    // non-AV1 streams within a ~1080p budget first, largest first.
    for (final v in videoVariants) {
      addUrl(v);
    }
    // 2. Original file URL (normally already included via alternates).
    addUrl(fileUrl);

    // 3. If the original is a static1.e621.net/data/xx/yy/<md5>.(webm|mp4) URL,
    // add the deterministic transcoded-sample URLs e621 generates in case the
    // API response carried no `alternates` or the raw original fails to decode.
    if (fileUrl != null) {
      final match = RegExp(
        r'^(https?://[^/]+/data/)([0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{32})\.(?:webm|mp4)$',
        caseSensitive: false,
      ).firstMatch(fileUrl!.trim());
      if (match != null) {
        final base = match.group(1)!;
        final sub = match.group(2)!;
        addUrl('${base}sample/${sub}_720p.mp4');
        addUrl('${base}sample/${sub}_480p.mp4');
        addUrl('${base}sample/${sub}_alt.mp4');
      }
    }

    return result;
  }

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

  static void _collectVideoUrlsFromNode(dynamic node, List<String> target) {
    if (node == null) return;
    if (node is String) {
      final trimmed = node.trim();
      final lower = trimmed.toLowerCase();
      if (lower.endsWith('.mp4') || lower.endsWith('.webm')) {
        if (!target.contains(trimmed)) target.add(trimmed);
      }
      return;
    }
    if (node is List) {
      for (final item in node) {
        _collectVideoUrlsFromNode(item, target);
      }
      return;
    }
    if (node is Map) {
      // Extract direct url / urls first
      if (node['url'] != null) {
        _collectVideoUrlsFromNode(node['url'], target);
      }
      if (node['mp4'] != null) {
        _collectVideoUrlsFromNode(node['mp4'], target);
      }
      if (node['webm'] != null) {
        _collectVideoUrlsFromNode(node['webm'], target);
      }
      if (node['urls'] is List) {
        _collectVideoUrlsFromNode(node['urls'], target);
      }
      // Recurse into common variant containers in priority order
      for (final key in const ['variants', '720p', '480p', 'samples', 'original', 'alternates']) {
        if (node[key] != null) {
          _collectVideoUrlsFromNode(node[key], target);
        }
      }
    }
  }

  /// Collects the `alternates` block of an e621 post (`original`, `variants.*`,
  /// `samples.*`, and legacy top-level `720p` / `480p`) and appends the URLs to
  /// [target] ordered from best to worst playback candidate.
  ///
  /// Ranking (earlier wins):
  ///  1. Non-AV1 before AV1 (AV1 hardware decode is rare on phones, so it
  ///     falls back to slow software decoding).
  ///  2. Streams within a ~1080p pixel budget before larger ones (4K / high
  ///     bitrate originals stall mobile decoders and cause UI lag).
  ///  3. Larger frames first (best quality that fits the budget).
  ///  4. The untouched original before an equally sized transcode.
  static void _collectRankedAlternates(dynamic alternates, List<String> target) {
    if (alternates is! Map) return;

    final entries = <_VideoCandidate>[];

    void addEntry(dynamic node) {
      if (node is! Map) return;
      final url = node['url'];
      if (url is! String) return;
      final trimmed = url.trim();
      final lower = trimmed.toLowerCase();
      if (!lower.endsWith('.mp4') && !lower.endsWith('.webm')) return;
      if (entries.any((e) => e.url == trimmed)) return;
      entries.add(_VideoCandidate(
        url: trimmed,
        width: node['width'] is num ? (node['width'] as num).toInt() : null,
        height: node['height'] is num ? (node['height'] as num).toInt() : null,
        codec: node['codec']?.toString().toLowerCase(),
        index: entries.length,
      ));
    }

    void addGroup(dynamic group) {
      if (group is! Map) return;
      if (group['url'] is String) {
        addEntry(group);
        return;
      }
      for (final value in group.values) {
        addEntry(value);
      }
    }

    addEntry(alternates['original']);
    addGroup(alternates['variants']);
    addGroup(alternates['samples']);
    addEntry(alternates['720p']);
    addEntry(alternates['480p']);

    entries.sort();
    for (final e in entries) {
      if (!target.contains(e.url)) target.add(e.url);
    }
  }

  static bool _isVideoOrFlashUrl(String? url) {
    if (url == null) return false;
    final lower = url.trim().toLowerCase();
    return lower.endsWith('.webm') || lower.endsWith('.mp4') || lower.endsWith('.swf');
  }

  factory E621Post.fromJson(Map<String, dynamic> json) {
    // 1. Files & URLs (Support both v2 'files' object and legacy v1 'file', 'sample', 'preview')
    String? fileUrl;
    String? previewUrl;
    String ext = '';
    String? md5;
    final List<String> videoVariants = [];

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

      _collectRankedAlternates(files['alternates'], videoVariants);
      _collectRankedAlternates(sample?['alternates'], videoVariants);
      _collectVideoUrlsFromNode(files['variants'], videoVariants);
      _collectVideoUrlsFromNode(files['alternates'], videoVariants);
      _collectVideoUrlsFromNode(sample, videoVariants);
    }

    // Fallback to legacy v1 structure if fields were not extracted from v2 'files'
    if (json['file'] is Map) {
      fileUrl ??= json['file']['url'] as String?;
      if (ext.isEmpty && json['file']['ext'] != null) {
        ext = json['file']['ext'].toString();
      }
      md5 ??= json['file']['md5']?.toString();
    }

    if (json['sample'] is Map) {
      final sampleMap = json['sample'] as Map;
      _collectRankedAlternates(sampleMap['alternates'], videoVariants);
      _collectVideoUrlsFromNode(sampleMap['alternates'], videoVariants);
      final sampleUrl = sampleMap['url'] as String?;
      if (_isVideoOrFlashUrl(sampleUrl)) {
        _collectVideoUrlsFromNode(sampleUrl, videoVariants);
      } else {
        previewUrl ??= sampleUrl;
      }
    }
    if (json['alternates'] != null) {
      _collectRankedAlternates(json['alternates'], videoVariants);
      _collectVideoUrlsFromNode(json['alternates'], videoVariants);
    }

    final rawPreviewUrl = json['preview'] is Map ? json['preview']['url'] as String? : null;
    if (previewUrl == null || _isVideoOrFlashUrl(previewUrl)) {
      previewUrl = !_isVideoOrFlashUrl(rawPreviewUrl) ? rawPreviewUrl : null;
    }

    ext = ext.trim().toLowerCase();

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
      if (videoVariants.isEmpty && (ext == 'webm' || ext == 'mp4')) {
        final alternates = json['sample'] is Map ? json['sample']['alternates'] : null;
        if (alternates is Map) {
          // Real e621 names: <md5>_720p.mp4, <md5>_480p.mp4 and <md5>_alt.mp4
          // (full-size H.264). Listed in hardware-friendliness order.
          final samples = alternates['samples'];
          if ((samples is Map && samples['720p'] is Map) || alternates['720p'] is Map) {
            videoVariants.add('https://static1.e621.net/data/sample/_720p.mp4');
          }
          if ((samples is Map && samples['480p'] is Map) || alternates['480p'] is Map) {
            videoVariants.add('https://static1.e621.net/data/sample/_480p.mp4');
          }
          final variants = alternates['variants'];
          if (variants is Map && variants['mp4'] is Map) {
            videoVariants.add('https://static1.e621.net/data/sample/_alt.mp4');
          }
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
          ext = filename.substring(dotIndex + 1).toLowerCase();
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
      videoVariants: videoVariants,
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
      'videoVariants': videoVariants,
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
      videoVariants: List<String>.from(json['videoVariants'] ?? const []),
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

/// A playable video source from an e621 `alternates` block, orderable by how
/// suitable it is for smooth playback on mobile devices.
class _VideoCandidate implements Comparable<_VideoCandidate> {
  /// Roughly 1080p (1920x1088 after macroblock padding). Anything above this
  /// (e.g. 4K originals) tends to stall phone decoders.
  static const int _pixelBudget = 1920 * 1088;

  final String url;
  final int? width;
  final int? height;
  final String? codec;
  final int index;

  const _VideoCandidate({
    required this.url,
    required this.width,
    required this.height,
    required this.codec,
    required this.index,
  });

  bool get _isAv1 => codec != null && (codec!.startsWith('av01') || codec!.contains('av1'));

  int get _pixels => (width ?? 0) * (height ?? 0);

  bool get _overBudget => _pixels > _pixelBudget;

  @override
  int compareTo(_VideoCandidate other) {
    if (_isAv1 != other._isAv1) return _isAv1 ? 1 : -1;
    if (_overBudget != other._overBudget) return _overBudget ? 1 : -1;
    if (_pixels != other._pixels) return other._pixels.compareTo(_pixels);
    return index.compareTo(other.index);
  }
}
