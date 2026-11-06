import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/post_model.dart';
import '../models/ref_board_model.dart';
import '../providers/auth_provider.dart';
import '../providers/boards_provider.dart';
import '../providers/ref_boards_provider.dart';
import '../services/board_share_service.dart';
import '../services/e621_collections_api.dart';
import 'board_detail_page.dart';
import 'details_page.dart';
import 'ref_canvas_page.dart';

class SharedBoardPreviewPage extends StatefulWidget {
  final SharedBoardPayload payload;

  const SharedBoardPreviewPage({
    super.key,
    required this.payload,
  });

  @override
  State<SharedBoardPreviewPage> createState() => _SharedBoardPreviewPageState();
}

class _SharedBoardPreviewPageState extends State<SharedBoardPreviewPage> {
  final TransformationController _canvasController = TransformationController();

  bool _isLoading = true;
  String? _errorMessage;
  List<E621Post> _hydratedPosts = [];
  List<RefBoardItem> _hydratedRefItems = [];

  // View mode when previewing a shared Ref Canvas: true = 2D Canvas, false = Post Grid
  bool _show2DCanvasPreview = true;

  // Saved state tracking so user doesn't accidentally duplicate-save
  String? _savedBoardId;
  String? _savedRefBoardId;

  static const ColorFilter _grayscaleFilter = ColorFilter.matrix([
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0,      0,      0,      1, 0,
  ]);

  @override
  void initState() {
    super.initState();
    _hydrateFromApi();
  }

  @override
  void dispose() {
    _canvasController.dispose();
    super.dispose();
  }

  Future<void> _hydrateFromApi() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders, host: auth.host);
    final ids = widget.payload.allReferencedPostIds;

    try {
      if (ids.isEmpty) {
        final builtItems = <RefBoardItem>[];
        if (widget.payload.isRefCanvas) {
          for (int i = 0; i < widget.payload.refItems.length; i++) {
            builtItems.add(widget.payload.refItems[i].toRefBoardItem(i));
          }
        }
        if (mounted) {
          setState(() {
            _hydratedPosts = [];
            _hydratedRefItems = builtItems;
            _isLoading = false;
          });
        }
        return;
      }

      final postMap = await api.getPostsByIds(ids);
      final orderedPosts = ids.map((id) => postMap[id]).whereType<E621Post>().toList();

      final builtRefItems = <RefBoardItem>[];
      if (widget.payload.isRefCanvas) {
        for (int i = 0; i < widget.payload.refItems.length; i++) {
          final raw = widget.payload.refItems[i];
          final post = raw.postId != null ? postMap[raw.postId!] : null;
          builtRefItems.add(raw.toRefBoardItem(i, hydratedPost: post));
        }
      }

      if (mounted) {
        setState(() {
          _hydratedPosts = orderedPosts;
          _hydratedRefItems = builtRefItems;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not load posts from ${auth.siteName}.';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleSaveAsBoard() async {
    final boardsProvider = Provider.of<BoardsProvider>(context, listen: false);

    if (_savedBoardId != null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => BoardDetailPage(boardId: _savedBoardId!)),
      );
      return;
    }

    final saved = await boardsProvider.importSharedBoard(
      name: widget.payload.name,
      postIds: widget.payload.allReferencedPostIds,
      posts: _hydratedPosts,
    );

    if (!mounted) return;
    setState(() {
      _savedBoardId = saved.id;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved "${saved.name}" to your Saved Boards!'),
        action: SnackBarAction(
          label: 'OPEN',
          onPressed: () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => BoardDetailPage(boardId: saved.id)),
            );
          },
        ),
      ),
    );
  }

  Future<void> _handleSaveOrOpenRefCanvas() async {
    final refProvider = Provider.of<RefBoardsProvider>(context, listen: false);

    if (_savedRefBoardId != null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => RefCanvasPage(boardId: _savedRefBoardId!)),
      );
      return;
    }

    final RefBoard created;
    if (widget.payload.isRefCanvas) {
      final validItems = _hydratedRefItems
          .where((item) => item.imageUrl.isNotEmpty || (item.previewUrl?.isNotEmpty ?? false))
          .toList();
      created = await refProvider.importSharedRefBoard(
        name: widget.payload.name,
        items: validItems,
        backgroundColorHex: widget.payload.backgroundColorHex,
        isLocked: widget.payload.isLocked,
      );
    } else {
      created = await refProvider.createRefBoard(
        'Ref: ${widget.payload.name}',
        initialPosts: _hydratedPosts,
      );
    }

    if (!mounted) return;
    setState(() {
      _savedRefBoardId = created.id;
    });

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => RefCanvasPage(boardId: created.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRef = widget.payload.isRefCanvas;
    final accentColor = isRef ? Colors.cyanAccent : Theme.of(context).colorScheme.primary;
    final totalExpected = widget.payload.itemCount;
    final loadedCount = isRef
        ? _hydratedRefItems
            .where((i) => i.imageUrl.isNotEmpty || (i.previewUrl?.isNotEmpty ?? false))
            .length
        : _hydratedPosts.length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: accentColor.withValues(alpha: 0.6)),
                  ),
                  child: Text(
                    isRef ? 'SHARED REF CANVAS' : 'SHARED BOARD',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6,
                      color: isRef ? Colors.cyanAccent : Colors.blueAccent,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.payload.name,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                if (widget.payload.author != null) 'by @${widget.payload.author}',
                if (_isLoading)
                  'Loading $totalExpected ${isRef ? "refs" : "arts"}...'
                else
                  '$loadedCount of $totalExpected ${isRef ? (totalExpected == 1 ? "ref" : "refs") : (totalExpected == 1 ? "art" : "arts")} loaded',
              ].join(' • '),
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        ),
        actions: [
          if (isRef && !_isLoading)
            IconButton(
              icon: Icon(_show2DCanvasPreview ? Icons.grid_on_rounded : Icons.draw_outlined),
              tooltip: _show2DCanvasPreview ? 'Switch to Grid View' : 'Switch to 2D Canvas View',
              onPressed: () {
                setState(() {
                  _show2DCanvasPreview = !_show2DCanvasPreview;
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _hydrateFromApi,
          ),
        ],
      ),
      body: _buildBody(isRef),
      bottomNavigationBar: _buildBottomBar(context, isRef),
    );
  }

  Widget _buildBody(bool isRef) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: isRef ? Colors.cyanAccent : null,
            ),
            const SizedBox(height: 16),
            Text(
              'Fetching shared ${isRef ? "canvas references" : "board arts"}...',
              style: TextStyle(color: Colors.grey[400], fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                onPressed: _hydrateFromApi,
              ),
            ],
          ),
        ),
      );
    }

    if (isRef && _show2DCanvasPreview) {
      return _buildRefCanvasInteractivePreview();
    }

    return _buildPostsGrid();
  }

  Widget _buildRefCanvasInteractivePreview() {
    final sortedItems = List<RefBoardItem>.from(_hydratedRefItems)
      ..sort((a, b) => a.zIndex.compareTo(b.zIndex));

    if (sortedItems.isEmpty) {
      return const Center(
        child: Text('This shared Ref Canvas is empty.', style: TextStyle(color: Colors.grey)),
      );
    }

    return Stack(
      children: [
        Container(
          color: const Color(0xFF191919),
          child: InteractiveViewer(
            transformationController: _canvasController,
            boundaryMargin: const EdgeInsets.all(5000.0),
            minScale: 0.05,
            maxScale: 6.0,
            child: SizedBox(
              width: 6000,
              height: 6000,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final item in sortedItems)
                    _buildPreviewCanvasItem(item),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: IgnorePointer(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.4)),
                ),
                child: const Text(
                  'Preview Mode • Pan & zoom freely, or tap an art to view details',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewCanvasItem(RefBoardItem item) {
    final url = item.imageUrl.isNotEmpty ? item.imageUrl : (item.previewUrl ?? '');
    if (url.isEmpty) return const SizedBox.shrink();

    Widget imageContent = CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (context, _) => Container(
        color: Colors.grey[850],
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      errorWidget: (context, _, _) => Container(
        color: Colors.grey[850],
        child: const Icon(Icons.broken_image, color: Colors.grey),
      ),
    );

    if (item.isGrayscale) {
      imageContent = ColorFiltered(
        colorFilter: _grayscaleFilter,
        child: imageContent,
      );
    }

    imageContent = Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(
        item.isFlippedH ? -1.0 : 1.0,
        item.isFlippedV ? -1.0 : 1.0,
        1.0,
      ),
      child: imageContent,
    );

    if (item.rotation != 0.0) {
      imageContent = Transform.rotate(
        angle: item.rotation,
        child: imageContent,
      );
    }

    return Positioned(
      left: item.x,
      top: item.y,
      width: item.width,
      height: item.height,
      child: GestureDetector(
        onTap: item.post == null
            ? null
            : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PostDetailPage(
                      post: item.post!,
                      posts: _hydratedPosts.isNotEmpty ? _hydratedPosts : [item.post!],
                      initialIndex: _hydratedPosts.indexOf(item.post!).clamp(0, _hydratedPosts.length),
                      heroTagPrefix: 'shared-ref-${item.id}',
                    ),
                  ),
                );
              },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 10,
                offset: const Offset(2, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: imageContent,
          ),
        ),
      ),
    );
  }

  Widget _buildPostsGrid() {
    if (_hydratedPosts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.collections_bookmark_outlined, size: 56, color: Colors.grey[600]),
              const SizedBox(height: 12),
              Text(
                widget.payload.itemCount == 0
                    ? 'This shared board has no posts yet.'
                    : 'No posts could be displayed (they may be filtered by Safe Mode or deleted).',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[400]),
              ),
            ],
          ),
        ),
      );
    }

    final filteredDiff = widget.payload.allReferencedPostIds.length - _hydratedPosts.length;

    return Column(
      children: [
        if (filteredDiff > 0)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: Colors.orangeAccent.withValues(alpha: 0.12),
            child: Text(
              '$filteredDiff ${filteredDiff == 1 ? "post was" : "posts were"} hidden by Safe Mode or unavailable on this host.',
              style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
            ),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8.0),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8.0,
              mainAxisSpacing: 8.0,
              childAspectRatio: 0.72,
            ),
            itemCount: _hydratedPosts.length,
            itemBuilder: (context, index) {
              final post = _hydratedPosts[index];
              final isVideo = post.extension == 'webm' || post.extension == 'mp4';

              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PostDetailPage(
                        post: post,
                        posts: _hydratedPosts,
                        initialIndex: index,
                        heroTagPrefix: 'shared-board-preview',
                      ),
                    ),
                  );
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Hero(
                      tag: postHeroTag('shared-board-preview', index, post),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8.0),
                        child: CachedNetworkImage(
                          imageUrl: post.previewUrl ?? '',
                          fit: BoxFit.cover,
                          placeholder: (context, _) => Container(color: Colors.grey[850]),
                          errorWidget: (context, _, _) => const Icon(Icons.broken_image),
                        ),
                      ),
                    ),
                    if (isVideo)
                      const Positioned(
                        top: 6,
                        right: 6,
                        child: Icon(Icons.movie, color: Colors.white, size: 18),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar(BuildContext context, bool isRef) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(top: BorderSide(color: Colors.grey[800]!)),
      ),
      child: SafeArea(
        top: false,
        child: isRef
            ? Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        side: BorderSide(color: Colors.grey[700]!),
                      ),
                      icon: Icon(
                        _savedBoardId != null
                            ? Icons.check_circle_outline
                            : Icons.collections_bookmark_outlined,
                        size: 18,
                      ),
                      label: Text(_savedBoardId != null ? 'Open Board' : 'Save as Board'),
                      onPressed: _isLoading ? null : _handleSaveAsBoard,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.cyanAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      icon: const Icon(Icons.draw, size: 18),
                      label: Text(
                        _savedRefBoardId != null
                            ? 'Open Ref Canvas'
                            : 'Save to Ref Canvases',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      onPressed: _isLoading ? null : _handleSaveOrOpenRefCanvas,
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.cyanAccent,
                        side: const BorderSide(color: Colors.cyanAccent),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      icon: const Icon(Icons.draw_outlined, size: 18),
                      label: const Text('Open in Canvas'),
                      onPressed: _isLoading ? null : _handleSaveOrOpenRefCanvas,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      icon: Icon(
                        _savedBoardId != null ? Icons.check_circle : Icons.bookmark_add_outlined,
                        size: 18,
                      ),
                      label: Text(
                        _savedBoardId != null ? 'Saved • Open Board' : 'Save to My Boards',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      onPressed: _isLoading ? null : _handleSaveAsBoard,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

