import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/ref_board_model.dart';
import '../models/post_model.dart';
import '../providers/ref_boards_provider.dart';
import '../providers/boards_provider.dart';
import '../providers/auth_provider.dart';
import '../services/download_service.dart';
import 'details_page.dart';

class RefCanvasPage extends StatefulWidget {
  final String boardId;

  const RefCanvasPage({super.key, required this.boardId});

  @override
  State<RefCanvasPage> createState() => _RefCanvasPageState();
}

class _RefCanvasPageState extends State<RefCanvasPage> {
  final TransformationController _transController = TransformationController();
  String? _selectedItemId;
  bool _isZenMode = false;
  bool _isResizing = false;

  // Grayscale matrix for value checking
  static const ColorFilter _grayscaleFilter = ColorFilter.matrix([
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0,      0,      0,      1, 0,
  ]);

  @override
  void dispose() {
    _transController.dispose();
    super.dispose();
  }

  double get _currentScale => _transController.value.getMaxScaleOnAxis();

  void _toggleZenMode() {
    setState(() {
      _isZenMode = !_isZenMode;
    });
    if (_isZenMode) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _resetZoom() {
    _transController.value = Matrix4.identity();
  }

  void _showRenameDialog(RefBoardsProvider provider, RefBoard board) {
    final controller = TextEditingController(text: board.name);
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Rename Ref Board'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Board Name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                await provider.renameRefBoard(board.id, newName);
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(RefBoardsProvider provider, RefBoard board) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Delete Ref Board?'),
        content: Text('Are you sure you want to delete "${board.name}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () async {
              await provider.deleteRefBoard(board.id);
              if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showAddContentSheet(RefBoardsProvider refProvider, BoardsProvider boardsProvider, RefBoard board) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _AddContentModal(
        refBoard: board,
        refProvider: refProvider,
        boardsProvider: boardsProvider,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final refProvider = Provider.of<RefBoardsProvider>(context);
    final boardsProvider = Provider.of<BoardsProvider>(context);
    final board = refProvider.getRefBoardById(widget.boardId);

    if (board == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ref Canvas')),
        body: const Center(child: Text('Board not found.')),
      );
    }

    final sortedItems = List<RefBoardItem>.from(board.items)
      ..sort((a, b) => a.zIndex.compareTo(b.zIndex));

    final selectedItem = _selectedItemId == null
        ? null
        : sortedItems.where((i) => i.id == _selectedItemId).firstOrNull;

    return Scaffold(
      backgroundColor: const Color(0xFF191919),
      appBar: _isZenMode
          ? null
          : AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.9),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(board.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  Text(
                    '${board.itemCount} ${board.itemCount == 1 ? "ref" : "refs"}${board.isLocked ? " • Locked" : ""}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                ],
              ),
              actions: [
                IconButton(
                  icon: Icon(board.isLocked ? Icons.lock : Icons.lock_open_outlined),
                  color: board.isLocked ? Colors.amberAccent : Colors.grey[400],
                  tooltip: board.isLocked ? 'Unlock Canvas' : 'Lock Canvas (Prevent Movement)',
                  onPressed: () => refProvider.toggleBoardLock(board.id),
                ),
                IconButton(
                  icon: const Icon(Icons.grid_view_rounded),
                  tooltip: 'Auto-Pack / Arrange Items',
                  onPressed: () {
                    refProvider.autoArrangeBoard(board.id);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Auto-arranged items in neat grid!'), duration: Duration(seconds: 1)),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  tooltip: 'Add Art or Import Board',
                  onPressed: () => _showAddContentSheet(refProvider, boardsProvider, board),
                ),
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  tooltip: 'Zen / Fullscreen Drawing Mode',
                  onPressed: _toggleZenMode,
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (val) {
                    if (val == 'reset') {
                      _resetZoom();
                    } else if (val == 'rename') {
                      _showRenameDialog(refProvider, board);
                    } else if (val == 'delete') {
                      _showDeleteDialog(refProvider, board);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'reset',
                      child: Row(
                        children: [
                          Icon(Icons.center_focus_strong, size: 20),
                          SizedBox(width: 8),
                          Text('Reset Zoom & Center'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'rename',
                      child: Row(
                        children: [
                          Icon(Icons.edit_outlined, size: 20),
                          SizedBox(width: 8),
                          Text('Rename Board'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                          SizedBox(width: 8),
                          Text('Delete Board', style: TextStyle(color: Colors.redAccent)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
      body: Stack(
        children: [
          // Infinite / Freeform Canvas
          GestureDetector(
            onTap: () {
              if (_selectedItemId != null) {
                setState(() => _selectedItemId = null);
              }
            },
            child: InteractiveViewer(
              transformationController: _transController,
              boundaryMargin: const EdgeInsets.all(5000.0),
              minScale: 0.05,
              maxScale: 8.0,
              panEnabled: true,
              scaleEnabled: true,
              child: SizedBox(
                width: 6000,
                height: 6000,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Canvas grid texture / background
                    CustomPaint(
                      size: const Size(6000, 6000),
                      painter: _CanvasGridPainter(),
                    ),
                    if (sortedItems.isEmpty)
                      Positioned(
                        left: 200,
                        top: 200,
                        child: Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.grey[900]?.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey[800]!),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.draw, color: Colors.blueAccent, size: 28),
                                  SizedBox(width: 12),
                                  Text(
                                    'Reference Canvas',
                                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '• Tap the + icon to add arts or import entire saved boards.\n'
                                '• Pan with touch/mouse, zoom in/out to inspect details.\n'
                                '• Tap any art to flip horizontally, vertically, or toggle grayscale.\n'
                                '• Hit Fullscreen to hide all UI while drawing!',
                                style: TextStyle(color: Colors.grey[400], height: 1.5),
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.add),
                                label: const Text('Add References Now'),
                                onPressed: () => _showAddContentSheet(refProvider, boardsProvider, board),
                              ),
                            ],
                          ),
                        ),
                      ),
                    for (final item in sortedItems)
                      _buildCanvasItem(item, board, refProvider),
                  ],
                ),
              ),
            ),
          ),

          // Zen mode exit button
          if (_isZenMode)
            Positioned(
              top: 16,
              right: 16,
              child: SafeArea(
                child: Material(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _toggleZenMode,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.fullscreen_exit, size: 20, color: Colors.white70),
                          SizedBox(width: 6),
                          Text('Exit Zen', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Contextual Selected Item Toolbar
          if (selectedItem != null && !_isZenMode)
            Positioned(
              bottom: 24,
              left: 20,
              right: 20,
              child: Center(
                child: _buildItemToolbar(selectedItem, board, refProvider),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCanvasItem(RefBoardItem item, RefBoard board, RefBoardsProvider provider) {
    final isSelected = _selectedItemId == item.id;

    Widget imageContent = CachedNetworkImage(
      imageUrl: item.imageUrl.isNotEmpty ? item.imageUrl : (item.previewUrl ?? ''),
      fit: BoxFit.cover,
      placeholder: (context, url) => Container(
        color: Colors.grey[850],
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      errorWidget: (context, url, error) => Container(
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

    // Mirroring / Flip transformations
    imageContent = Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(
        item.isFlippedH ? -1.0 : 1.0,
        item.isFlippedV ? -1.0 : 1.0,
        1.0,
      ),
      child: imageContent,
    );

    return Positioned(
      left: item.x,
      top: item.y,
      width: item.width,
      height: item.height,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedItemId = item.id;
          });
        },
        onPanUpdate: board.isLocked || _isResizing
            ? null
            : (details) {
                final scale = math.max(0.01, _currentScale);
                provider.updateItemTransform(
                  board.id,
                  item.id,
                  x: item.x + details.delta.dx / scale,
                  y: item.y + details.delta.dy / scale,
                );
              },
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isSelected ? Colors.cyanAccent : Colors.transparent,
                  width: isSelected ? 3.0 : 0.0,
                ),
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
            // Resize corner handle when selected
            if (isSelected && !board.isLocked)
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onPanStart: (_) => setState(() => _isResizing = true),
                  onPanEnd: (_) => setState(() => _isResizing = false),
                  onPanCancel: () => setState(() => _isResizing = false),
                  onPanUpdate: (details) {
                    final scale = math.max(0.01, _currentScale);
                    final newW = math.max(100.0, item.width + details.delta.dx / scale);
                    final newH = math.max(100.0, item.height + details.delta.dy / scale);
                    provider.updateItemTransform(
                      board.id,
                      item.id,
                      width: newW,
                      height: newH,
                    );
                  },
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: const BoxDecoration(
                      color: Colors.cyanAccent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.aspect_ratio, size: 16, color: Colors.black),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemToolbar(RefBoardItem item, RefBoard board, RefBoardsProvider provider) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey[900]?.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.6), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black87, blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              Icons.flip,
              color: item.isFlippedH ? Colors.cyanAccent : Colors.white,
            ),
            tooltip: 'Flip Horizontal (Mirror)',
            onPressed: () => provider.toggleItemFlipH(board.id, item.id),
          ),
          IconButton(
            icon: Icon(
              Icons.flip_camera_android_outlined,
              color: item.isFlippedV ? Colors.cyanAccent : Colors.white,
            ),
            tooltip: 'Flip Vertical',
            onPressed: () => provider.toggleItemFlipV(board.id, item.id),
          ),
          IconButton(
            icon: Icon(
              Icons.filter_b_and_w,
              color: item.isGrayscale ? Colors.cyanAccent : Colors.white,
            ),
            tooltip: 'B&W Grayscale (Value Check)',
            onPressed: () => provider.toggleItemGrayscale(board.id, item.id),
          ),
          const VerticalDivider(width: 12, thickness: 1, color: Colors.grey),
          IconButton(
            icon: const Icon(Icons.flip_to_front, color: Colors.white),
            tooltip: 'Bring to Front',
            onPressed: () => provider.bringToFront(board.id, item.id),
          ),
          IconButton(
            icon: const Icon(Icons.flip_to_back, color: Colors.white),
            tooltip: 'Send to Back',
            onPressed: () => provider.sendToBack(board.id, item.id),
          ),
          if (item.post != null) ...[
            IconButton(
              icon: const Icon(Icons.download_outlined, color: Colors.white),
              tooltip: 'Download Art',
              onPressed: () {
                final auth = Provider.of<AuthProvider>(context, listen: false);
                DownloadService.downloadWithFeedback(
                  context,
                  item.post!,
                  authHeaders: auth.authHeaders,
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.open_in_new, color: Colors.blueAccent),
              tooltip: 'View Full Post Details',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PostDetailPage(
                      post: item.post!,
                      posts: [item.post!],
                      initialIndex: 0,
                      heroTagPrefix: 'ref-canvas-${item.id}',
                    ),
                  ),
                );
              },
            ),
          ],
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'Remove from Canvas',
            onPressed: () {
              provider.removeItem(board.id, item.id);
              setState(() => _selectedItemId = null);
            },
          ),
        ],
      ),
    );
  }
}

/// Canvas Grid Pattern
class _CanvasGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final dotPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..style = PaintingStyle.fill;

    const double spacing = 60.0;
    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1.5, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Modal for adding individual arts or importing entire saved boards
class _AddContentModal extends StatefulWidget {
  final RefBoard refBoard;
  final RefBoardsProvider refProvider;
  final BoardsProvider boardsProvider;

  const _AddContentModal({
    required this.refBoard,
    required this.refProvider,
    required this.boardsProvider,
  });

  @override
  State<_AddContentModal> createState() => _AddContentModalState();
}

class _AddContentModalState extends State<_AddContentModal> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final savedBoards = widget.boardsProvider.boards;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            TabBar(
              controller: _tabController,
              indicatorColor: Colors.cyanAccent,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.grey,
              tabs: const [
                Tab(icon: Icon(Icons.collections_bookmark_outlined), text: 'Import Board'),
                Tab(icon: Icon(Icons.photo_library_outlined), text: 'Pick Art'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // 1. IMPORT ENTIRE BOARD TAB
                  savedBoards.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24.0),
                            child: Text(
                              'No saved boards yet.\nCreate boards or save posts to import them here.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: savedBoards.length,
                          itemBuilder: (context, index) {
                            final b = savedBoards[index];
                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  width: 50,
                                  height: 50,
                                  color: Colors.grey[800],
                                  child: b.coverUrl != null
                                      ? CachedNetworkImage(imageUrl: b.coverUrl!, fit: BoxFit.cover)
                                      : const Icon(Icons.photo_library),
                                ),
                              ),
                              title: Text(b.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('${b.postCount} arts'),
                              trailing: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.cyanAccent,
                                  foregroundColor: Colors.black,
                                ),
                                icon: const Icon(Icons.download, size: 16),
                                label: const Text('Import All'),
                                onPressed: () async {
                                  final count = await widget.refProvider.addEntireBoardToRefBoard(
                                    widget.refBoard.id,
                                    b,
                                  );
                                  if (context.mounted) {
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Imported $count arts from "${b.name}"!')),
                                    );
                                  }
                                },
                              ),
                            );
                          },
                        ),

                  // 2. PICK INDIVIDUAL ART TAB
                  _SavedArtsPicker(
                    scrollController: scrollController,
                    boardsProvider: widget.boardsProvider,
                    onSelectPost: (post) async {
                      await widget.refProvider.addPostToRefBoard(widget.refBoard.id, post);
                      if (context.mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Added art #${post.id} to Ref Board!')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SavedArtsPicker extends StatelessWidget {
  final ScrollController scrollController;
  final BoardsProvider boardsProvider;
  final ValueChanged<E621Post> onSelectPost;

  const _SavedArtsPicker({
    required this.scrollController,
    required this.boardsProvider,
    required this.onSelectPost,
  });

  @override
  Widget build(BuildContext context) {
    final Map<int, E621Post> uniquePosts = {};
    for (final b in boardsProvider.boards) {
      for (final p in b.posts) {
        uniquePosts[p.id] = p;
      }
    }
    final posts = uniquePosts.values.toList();

    if (posts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text(
            'No arts in your saved boards yet.\nSave arts from the gallery or details page to pick them here!',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.75,
      ),
      itemCount: posts.length,
      itemBuilder: (context, index) {
        final post = posts[index];
        return GestureDetector(
          onTap: () => onSelectPost(post),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: post.previewUrl ?? '',
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Container(color: Colors.grey[850]),
                  errorWidget: (context, url, error) => const Icon(Icons.broken_image),
                ),
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.add, color: Colors.cyanAccent, size: 16),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
