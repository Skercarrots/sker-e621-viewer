import 'dart:convert';
import 'dart:io';
import '../models/board_model.dart';
import '../models/ref_board_model.dart';
import '../models/post_model.dart';

enum SharedPayloadType {
  savedBoard,
  refCanvas,
}

/// Represents a decoded item from a shared Ref Canvas before/after API hydration.
class SharedRefItemData {
  final int? postId;
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
  final bool isFlippedH;
  final bool isFlippedV;
  final bool isGrayscale;
  final int zIndex;
  final String? fallbackImageUrl;

  const SharedRefItemData({
    this.postId,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotation = 0.0,
    this.isFlippedH = false,
    this.isFlippedV = false,
    this.isGrayscale = false,
    this.zIndex = 0,
    this.fallbackImageUrl,
  });

  RefBoardItem toRefBoardItem(int index, {E621Post? hydratedPost}) {
    final resolvedImage = hydratedPost?.fileUrl ??
        hydratedPost?.previewUrl ??
        fallbackImageUrl ??
        '';
    final resolvedPreview = hydratedPost?.previewUrl ?? fallbackImageUrl;

    return RefBoardItem(
      id: 'shared_item_${DateTime.now().microsecondsSinceEpoch}_$index',
      postId: postId ?? hydratedPost?.id,
      imageUrl: resolvedImage,
      previewUrl: resolvedPreview,
      x: x,
      y: y,
      width: width,
      height: height,
      rotation: rotation,
      isFlippedH: isFlippedH,
      isFlippedV: isFlippedV,
      isGrayscale: isGrayscale,
      zIndex: zIndex,
      post: hydratedPost,
    );
  }
}

/// Decoded payload for either a shared Saved Board or a shared Ref Canvas.
class SharedBoardPayload {
  final SharedPayloadType type;
  final String name;
  final String? author;
  final List<int> postIds;
  final List<SharedRefItemData> refItems;
  final String backgroundColorHex;
  final bool isLocked;

  const SharedBoardPayload({
    required this.type,
    required this.name,
    this.author,
    this.postIds = const [],
    this.refItems = const [],
    this.backgroundColorHex = '#1E1E1E',
    this.isLocked = false,
  });

  bool get isRefCanvas => type == SharedPayloadType.refCanvas;

  int get itemCount =>
      isRefCanvas ? refItems.length : postIds.length;

  /// All unique e621 post IDs referenced by this shared board or canvas.
  List<int> get allReferencedPostIds {
    if (!isRefCanvas) return postIds;
    final ids = <int>[];
    final seen = <int>{};
    for (final item in refItems) {
      final id = item.postId;
      if (id != null && id > 0 && seen.add(id)) {
        ids.add(id);
      }
    }
    return ids;
  }
}

/// Serverless compressor & parser for sharing Saved Boards (`SKER-B1:...`)
/// and Reference Canvases (`SKER-R1:...`) via compact codes or `sker://` links.
class BoardShareService {
  static const String boardPrefix = 'SKER-B1:';
  static const String refCanvasPrefix = 'SKER-R1:';
  static const String deepLinkScheme = 'sker';
  static const String deepLinkHost = 'share';

  /// Encodes a [Board] into a compact `SKER-B1:<base64Url>` share code.
  static String encodeBoard(Board board, {String? author}) {
    final ids = board.postIds.isNotEmpty
        ? board.postIds
        : board.posts.map((p) => p.id).toList();

    final map = <String, dynamic>{
      'v': 1,
      't': 'b',
      'n': board.name.trim().isEmpty ? 'Shared Board' : board.name.trim(),
      if (author != null && author.trim().isNotEmpty) 'a': author.trim(),
      'p': ids,
    };

    final compressed = _compressJson(map);
    return '$boardPrefix$compressed';
  }

  /// Encodes a [RefBoard] (including 2D positions, sizes, flips, grayscale, and z-order)
  /// into a compact `SKER-R1:<base64Url>` share code.
  static String encodeRefBoard(RefBoard board, {String? author}) {
    final itemsList = <List<dynamic>>[];
    for (final item in board.items) {
      final int flags = (item.isFlippedH ? 1 : 0) |
          (item.isFlippedV ? 2 : 0) |
          (item.isGrayscale ? 4 : 0);
      final int postId = item.postId ?? item.post?.id ?? 0;
      final int x = item.x.round();
      final int y = item.y.round();
      final int w = item.width.round();
      final int h = item.height.round();
      final int rotMillirad = (item.rotation * 1000).round();

      final tuple = <dynamic>[
        postId,
        x,
        y,
        w,
        h,
        rotMillirad,
        flags,
        item.zIndex,
        if (postId == 0 && item.imageUrl.isNotEmpty) item.imageUrl,
      ];
      itemsList.add(tuple);
    }

    final map = <String, dynamic>{
      'v': 1,
      't': 'r',
      'n': board.name.trim().isEmpty ? 'Shared Ref Canvas' : board.name.trim(),
      if (author != null && author.trim().isNotEmpty) 'a': author.trim(),
      if (board.backgroundColorHex != '#1E1E1E') 'bg': board.backgroundColorHex,
      if (board.isLocked) 'lk': 1,
      'i': itemsList,
    };

    final compressed = _compressJson(map);
    return '$refCanvasPrefix$compressed';
  }

  /// Builds a friendly message containing the share code.
  static String buildShareMessage({
    required String name,
    required int itemCount,
    required bool isRefCanvas,
    required String shareCode,
  }) {
    final kind = isRefCanvas ? 'Ref Canvas' : 'Saved Board';
    final unit = isRefCanvas
        ? (itemCount == 1 ? 'ref' : 'refs')
        : (itemCount == 1 ? 'art' : 'arts');
    return 'Check out my $kind "$name" ($itemCount $unit) on Sker e621 Viewer!\n'
        'Import this code in the app: $shareCode';
  }

  /// Extracts and decodes a [SharedBoardPayload] from any user input:
  /// - A raw share code (`SKER-B1:...` or `SKER-R1:...`)
  /// - A `sker://share?code=...` deep link
  /// - A multi-line chat message containing a code or link anywhere inside it
  static SharedBoardPayload? tryDecodeAny(String rawInput) {
    final extracted = extractShareCode(rawInput);
    if (extracted == null) return null;

    try {
      final bool isRef = extracted.startsWith(refCanvasPrefix);
      final String base64Part = isRef
          ? extracted.substring(refCanvasPrefix.length)
          : extracted.substring(boardPrefix.length);

      final map = _decompressJson(base64Part);
      if (map == null) return null;

      final typeStr = map['t']?.toString() ?? (isRef ? 'r' : 'b');
      final name = map['n']?.toString().trim();
      final author = map['a']?.toString().trim();

      if (typeStr == 'r') {
        final rawItems = map['i'] as List<dynamic>? ?? const [];
        final parsedItems = <SharedRefItemData>[];

        for (final entry in rawItems) {
          if (entry is List && entry.length >= 8) {
            final int rawPostId = (entry[0] as num?)?.toInt() ?? 0;
            final double x = (entry[1] as num?)?.toDouble() ?? 50.0;
            final double y = (entry[2] as num?)?.toDouble() ?? 50.0;
            final double w = (entry[3] as num?)?.toDouble() ?? 280.0;
            final double h = (entry[4] as num?)?.toDouble() ?? 380.0;
            final double rot = ((entry[5] as num?)?.toDouble() ?? 0.0) / 1000.0;
            final int flags = (entry[6] as num?)?.toInt() ?? 0;
            final int z = (entry[7] as num?)?.toInt() ?? 0;
            final String? fallbackUrl =
                entry.length > 8 ? entry[8]?.toString() : null;

            parsedItems.add(
              SharedRefItemData(
                postId: rawPostId > 0 ? rawPostId : null,
                x: x,
                y: y,
                width: w.clamp(50.0, 4000.0),
                height: h.clamp(50.0, 4000.0),
                rotation: rot,
                isFlippedH: (flags & 1) != 0,
                isFlippedV: (flags & 2) != 0,
                isGrayscale: (flags & 4) != 0,
                zIndex: z,
                fallbackImageUrl: fallbackUrl,
              ),
            );
          }
        }

        return SharedBoardPayload(
          type: SharedPayloadType.refCanvas,
          name: (name != null && name.isNotEmpty) ? name : 'Shared Ref Canvas',
          author: (author != null && author.isNotEmpty) ? author : null,
          refItems: parsedItems,
          backgroundColorHex: map['bg']?.toString() ?? '#1E1E1E',
          isLocked: map['lk'] == 1 || map['lk'] == true,
        );
      } else {
        final rawIds = map['p'] as List<dynamic>? ?? const [];
        final ids = rawIds
            .map((e) => (e as num?)?.toInt() ?? 0)
            .where((id) => id > 0)
            .toList();

        return SharedBoardPayload(
          type: SharedPayloadType.savedBoard,
          name: (name != null && name.isNotEmpty) ? name : 'Shared Board',
          author: (author != null && author.isNotEmpty) ? author : null,
          postIds: ids,
        );
      }
    } catch (_) {
      return null;
    }
  }

  /// Finds a `SKER-B1:...` or `SKER-R1:...` token inside arbitrary text or a `sker://` URI.
  static String? extractShareCode(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // 1. Check if the input itself or a line in the input contains a `sker://` URI
    final uriMatch = RegExp(r'sker://[^\s]+', caseSensitive: false).firstMatch(trimmed);
    if (uriMatch != null) {
      final uriStr = uriMatch.group(0)!;
      final uri = Uri.tryParse(uriStr);
      if (uri != null) {
        final codeParam = uri.queryParameters['code'] ?? uri.queryParameters['d'];
        if (codeParam != null && codeParam.isNotEmpty) {
          final fromParam = _matchRawCode(codeParam);
          if (fromParam != null) return fromParam;
        }
      }
    }

    // 2. Match `SKER-B1:<base64url>` or `SKER-R1:<base64url>` directly in the text
    return _matchRawCode(trimmed);
  }

  static String? _matchRawCode(String text) {
    final codeRegex = RegExp(r'(SKER-[BR]1:[A-Za-z0-9_\-=]+)');
    final match = codeRegex.firstMatch(text);
    return match?.group(1);
  }

  static String _compressJson(Map<String, dynamic> data) {
    final jsonBytes = utf8.encode(jsonEncode(data));
    final compressedBytes = zlib.encode(jsonBytes);
    return base64Url.encode(compressedBytes).replaceAll('=', '');
  }

  static Map<String, dynamic>? _decompressJson(String base64UrlStr) {
    final normalized = base64Url.normalize(base64UrlStr.trim());
    final compressedBytes = base64Url.decode(normalized);
    final jsonBytes = zlib.decode(compressedBytes);
    final decoded = jsonDecode(utf8.decode(jsonBytes));
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return null;
  }
}

