import 'post_model.dart';

/// Represents a single visual reference element placed on an interactive 2D Reference Canvas.
class RefBoardItem {
  final String id;
  final int? postId;
  final String imageUrl;
  final String? previewUrl;
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation; // in radians
  final bool isFlippedH;
  final bool isFlippedV;
  final bool isGrayscale;
  final int zIndex;
  final E621Post? post;

  const RefBoardItem({
    required this.id,
    this.postId,
    required this.imageUrl,
    this.previewUrl,
    this.x = 0.0,
    this.y = 0.0,
    this.width = 260.0,
    this.height = 360.0,
    this.rotation = 0.0,
    this.isFlippedH = false,
    this.isFlippedV = false,
    this.isGrayscale = false,
    this.zIndex = 0,
    this.post,
  });

  RefBoardItem copyWith({
    String? id,
    int? postId,
    String? imageUrl,
    String? previewUrl,
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    bool? isFlippedH,
    bool? isFlippedV,
    bool? isGrayscale,
    int? zIndex,
    E621Post? post,
  }) {
    return RefBoardItem(
      id: id ?? this.id,
      postId: postId ?? this.postId,
      imageUrl: imageUrl ?? this.imageUrl,
      previewUrl: previewUrl ?? this.previewUrl,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
      isFlippedH: isFlippedH ?? this.isFlippedH,
      isFlippedV: isFlippedV ?? this.isFlippedV,
      isGrayscale: isGrayscale ?? this.isGrayscale,
      zIndex: zIndex ?? this.zIndex,
      post: post ?? this.post,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'postId': postId,
      'imageUrl': imageUrl,
      'previewUrl': previewUrl,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'rotation': rotation,
      'isFlippedH': isFlippedH,
      'isFlippedV': isFlippedV,
      'isGrayscale': isGrayscale,
      'zIndex': zIndex,
      if (post != null) 'post': post!.toJson(),
    };
  }

  factory RefBoardItem.fromJson(Map<String, dynamic> json) {
    E621Post? parsedPost;
    if (json['post'] is Map<String, dynamic>) {
      parsedPost = E621Post.fromLocalJson(json['post'] as Map<String, dynamic>);
    }

    return RefBoardItem(
      id: json['id']?.toString() ?? DateTime.now().microsecondsSinceEpoch.toString(),
      postId: (json['postId'] as num?)?.toInt(),
      imageUrl: json['imageUrl']?.toString() ?? '',
      previewUrl: json['previewUrl']?.toString(),
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      width: (json['width'] as num?)?.toDouble() ?? 260.0,
      height: (json['height'] as num?)?.toDouble() ?? 360.0,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      isFlippedH: json['isFlippedH'] == true,
      isFlippedV: json['isFlippedV'] == true,
      isGrayscale: json['isGrayscale'] == true,
      zIndex: (json['zIndex'] as num?)?.toInt() ?? 0,
      post: parsedPost,
    );
  }
}

/// Represents an interactive drawing reference canvas board.
class RefBoard {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<RefBoardItem> items;
  final bool isLocked;
  final String backgroundColorHex;

  const RefBoard({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.items,
    this.isLocked = false,
    this.backgroundColorHex = '#1E1E1E',
  });

  int get itemCount => items.length;

  String? get coverUrl {
    for (final item in items) {
      if (item.previewUrl != null && item.previewUrl!.isNotEmpty) {
        return item.previewUrl;
      }
      if (item.imageUrl.isNotEmpty) {
        return item.imageUrl;
      }
    }
    return null;
  }

  RefBoard copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<RefBoardItem>? items,
    bool? isLocked,
    String? backgroundColorHex,
  }) {
    return RefBoard(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      items: items ?? this.items,
      isLocked: isLocked ?? this.isLocked,
      backgroundColorHex: backgroundColorHex ?? this.backgroundColorHex,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'items': items.map((e) => e.toJson()).toList(),
      'isLocked': isLocked,
      'backgroundColorHex': backgroundColorHex,
    };
  }

  factory RefBoard.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? [];
    final items = rawItems
        .whereType<Map<String, dynamic>>()
        .map((e) => RefBoardItem.fromJson(e))
        .toList();

    DateTime parsedCreated = DateTime.now();
    if (json['createdAt'] != null) {
      final tryDate = DateTime.tryParse(json['createdAt'].toString());
      if (tryDate != null) parsedCreated = tryDate;
    }

    DateTime parsedUpdated = parsedCreated;
    if (json['updatedAt'] != null) {
      final tryDate = DateTime.tryParse(json['updatedAt'].toString());
      if (tryDate != null) parsedUpdated = tryDate;
    }

    return RefBoard(
      id: json['id']?.toString() ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'Untitled Ref Board',
      createdAt: parsedCreated,
      updatedAt: parsedUpdated,
      items: items,
      isLocked: json['isLocked'] == true,
      backgroundColorHex: json['backgroundColorHex']?.toString() ?? '#1E1E1E',
    );
  }
}

