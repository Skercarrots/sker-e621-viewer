import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/ref_board_model.dart';
import '../models/board_model.dart';
import '../providers/ref_boards_provider.dart';
import '../providers/boards_provider.dart';
import 'ref_canvas_page.dart';
import 'board_detail_page.dart';
import 'settings_page.dart';

class RefsStudioPage extends StatefulWidget {
  const RefsStudioPage({super.key});

  @override
  State<RefsStudioPage> createState() => _RefsStudioPageState();
}

class _RefsStudioPageState extends State<RefsStudioPage> with SingleTickerProviderStateMixin {
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

  void _showCreateRefBoardDialog(BuildContext context, RefBoardsProvider provider) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('New Ref Canvas'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'e.g. Pose Studies, Anatomy, Lighting',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (val) async {
            if (val.trim().isNotEmpty) {
              final newBoard = await provider.createRefBoard(val.trim());
              if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              if (context.mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => RefCanvasPage(boardId: newBoard.id)),
                );
              }
            }
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black),
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                final newBoard = await provider.createRefBoard(name);
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                if (context.mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => RefCanvasPage(boardId: newBoard.id)),
                  );
                }
              }
            },
            child: const Text('Create Canvas'),
          ),
        ],
      ),
    );
  }

  void _showCreateBoardDialog(BuildContext context, BoardsProvider boardsProvider) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Create Saved Board'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'e.g. Dragons, Wallpapers, Favorites',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (val) async {
            if (val.trim().isNotEmpty) {
              await boardsProvider.createBoard(val.trim());
              if (dialogCtx.mounted) Navigator.pop(dialogCtx);
            }
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                await boardsProvider.createBoard(name);
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final refProvider = Provider.of<RefBoardsProvider>(context);
    final boardsProvider = Provider.of<BoardsProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Studio & Refs',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.cyanAccent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.grey,
          indicatorWeight: 3,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.draw_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Text('Ref Canvases'),
                  if (refProvider.refBoards.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.cyanAccent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${refProvider.refBoards.length}',
                        style: const TextStyle(fontSize: 10, color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.collections_bookmark_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Text('Saved Boards'),
                  if (boardsProvider.boards.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${boardsProvider.boards.length}',
                        style: const TextStyle(fontSize: 10, color: Colors.white70, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildRefCanvasesTab(context, refProvider, boardsProvider),
          _buildSavedBoardsTab(context, boardsProvider, refProvider),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.cyanAccent,
        foregroundColor: Colors.black,
        child: const Icon(Icons.add),
        onPressed: () {
          if (_tabController.index == 0) {
            _showCreateRefBoardDialog(context, refProvider);
          } else {
            _showCreateBoardDialog(context, boardsProvider);
          }
        },
      ),
    );
  }

  // ============================================================================
  // TAB 1: REF CANVASES (Interactive Reference Canvases)
  // ============================================================================
  Widget _buildRefCanvasesTab(
    BuildContext context,
    RefBoardsProvider refProvider,
    BoardsProvider boardsProvider,
  ) {
    if (refProvider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final boards = refProvider.refBoards;

    if (boards.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.grey[850],
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.draw_rounded,
                  size: 54,
                  color: Colors.cyanAccent,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'No Ref Canvases Yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Reference canvases give you an infinite workspace to pan, zoom, flip references, and draw comfortably.\nAdd single arts or import whole boards!',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[400], fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyanAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Create Ref Canvas', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () => _showCreateRefBoardDialog(context, refProvider),
              ),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: boards.length,
      itemBuilder: (context, index) {
        final b = boards[index];
        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => RefCanvasPage(boardId: b.id)),
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey[800]!),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildRefBoardPreview(b),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              b.name,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${b.itemCount} ${b.itemCount == 1 ? "ref" : "refs"}',
                              style: TextStyle(color: Colors.grey[400], fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, size: 18, color: Colors.grey),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onSelected: (val) async {
                          if (val == 'duplicate') {
                            await refProvider.duplicateRefBoard(b.id);
                          } else if (val == 'delete') {
                            await refProvider.deleteRefBoard(b.id);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'duplicate',
                            child: Row(
                              children: [
                                Icon(Icons.copy, size: 18),
                                SizedBox(width: 8),
                                Text('Duplicate Canvas'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                SizedBox(width: 8),
                                Text('Delete', style: TextStyle(color: Colors.redAccent)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRefBoardPreview(RefBoard board) {
    if (board.items.isEmpty) {
      return Container(
        color: const Color(0xFF1E1E1E),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.crop_free, size: 36, color: Colors.white24),
              SizedBox(height: 4),
              Text('Empty Canvas', style: TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ),
      );
    }

    if (board.items.length == 1) {
      final item = board.items.first;
      return CachedNetworkImage(
        imageUrl: item.previewUrl ?? item.imageUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        placeholder: (context, url) => Container(color: Colors.grey[850]),
        errorWidget: (context, url, error) => Container(
          color: Colors.grey[850],
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      );
    }

    // Mini collage of the first 4 items
    final count = board.items.length >= 4 ? 4 : (board.items.length >= 2 ? 2 : 1);
    final previewItems = board.items.take(count).toList();

    if (count == 2) {
      return Row(
        children: previewItems.map((item) {
          return Expanded(
            child: CachedNetworkImage(
              imageUrl: item.previewUrl ?? item.imageUrl,
              fit: BoxFit.cover,
              height: double.infinity,
              placeholder: (context, url) => Container(color: Colors.grey[850]),
              errorWidget: (context, url, error) => Container(color: Colors.grey[850]),
            ),
          );
        }).toList(),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: CachedNetworkImage(
                  imageUrl: previewItems[0].previewUrl ?? previewItems[0].imageUrl,
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (context, url) => Container(color: Colors.grey[850]),
                  errorWidget: (context, url, error) => Container(color: Colors.grey[850]),
                ),
              ),
              const SizedBox(width: 1),
              Expanded(
                child: CachedNetworkImage(
                  imageUrl: previewItems[1].previewUrl ?? previewItems[1].imageUrl,
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (context, url) => Container(color: Colors.grey[850]),
                  errorWidget: (context, url, error) => Container(color: Colors.grey[850]),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: CachedNetworkImage(
                  imageUrl: previewItems[2].previewUrl ?? previewItems[2].imageUrl,
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (context, url) => Container(color: Colors.grey[850]),
                  errorWidget: (context, url, error) => Container(color: Colors.grey[850]),
                ),
              ),
              const SizedBox(width: 1),
              Expanded(
                child: CachedNetworkImage(
                  imageUrl: previewItems[3].previewUrl ?? previewItems[3].imageUrl,
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (context, url) => Container(color: Colors.grey[850]),
                  errorWidget: (context, url, error) => Container(color: Colors.grey[850]),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ============================================================================
  // TAB 2: SAVED BOARDS (Migrated from Account)
  // ============================================================================
  Widget _buildSavedBoardsTab(
    BuildContext context,
    BoardsProvider boardsProvider,
    RefBoardsProvider refProvider,
  ) {
    if (boardsProvider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final boards = boardsProvider.boards;

    if (boards.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.grey[850],
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.collections_bookmark_outlined,
                  size: 54,
                  color: Colors.blueAccent,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'No Saved Boards Yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Create collections to bookmark and organize arts you like.\nYou can also open any board inside a Reference Canvas!',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[400], fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Create First Board', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () => _showCreateBoardDialog(context, boardsProvider),
              ),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: boards.length,
      itemBuilder: (context, index) {
        final b = boards[index];
        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => BoardDetailPage(boardId: b.id)),
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey[800]!),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildBoardCollage(b),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              b.name,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${b.postCount} ${b.postCount == 1 ? "art" : "arts"}',
                              style: TextStyle(color: Colors.grey[400], fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, size: 18, color: Colors.grey),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onSelected: (action) async {
                          if (action == 'open_ref') {
                            final refBoard = await refProvider.createFromSavedBoard(b);
                            if (context.mounted) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => RefCanvasPage(boardId: refBoard.id)),
                              );
                            }
                          } else if (action == 'delete') {
                            await boardsProvider.deleteBoard(b.id);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'open_ref',
                            child: Row(
                              children: [
                                Icon(Icons.draw, size: 18, color: Colors.cyanAccent),
                                SizedBox(width: 8),
                                Text('Open in Ref Canvas'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                SizedBox(width: 8),
                                Text('Delete Board', style: TextStyle(color: Colors.redAccent)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBoardCollage(Board board) {
    final posts = board.posts;
    if (posts.isEmpty) {
      return Container(
        color: Colors.grey[800],
        child: Center(
          child: Icon(Icons.folder_outlined, size: 40, color: Colors.grey[500]),
        ),
      );
    }

    if (posts.length == 1) {
      return CachedNetworkImage(
        imageUrl: posts[0].previewUrl ?? '',
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        placeholder: (context, url) => Container(color: Colors.grey[800]),
        errorWidget: (context, url, error) => Container(color: Colors.grey[800]),
      );
    }

    if (posts.length == 2) {
      return Row(
        children: [
          Expanded(
            child: CachedNetworkImage(
              imageUrl: posts[0].previewUrl ?? '',
              fit: BoxFit.cover,
              height: double.infinity,
              placeholder: (context, url) => Container(color: Colors.grey[800]),
              errorWidget: (context, url, error) => Container(color: Colors.grey[800]),
            ),
          ),
          const SizedBox(width: 1),
          Expanded(
            child: CachedNetworkImage(
              imageUrl: posts[1].previewUrl ?? '',
              fit: BoxFit.cover,
              height: double.infinity,
              placeholder: (context, url) => Container(color: Colors.grey[800]),
              errorWidget: (context, url, error) => Container(color: Colors.grey[800]),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: CachedNetworkImage(
                  imageUrl: posts[0].previewUrl ?? '',
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (context, url) => Container(color: Colors.grey[800]),
                  errorWidget: (context, url, error) => Container(color: Colors.grey[800]),
                ),
              ),
              const SizedBox(width: 1),
              Expanded(
                child: CachedNetworkImage(
                  imageUrl: posts[1].previewUrl ?? '',
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (context, url) => Container(color: Colors.grey[800]),
                  errorWidget: (context, url, error) => Container(color: Colors.grey[800]),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: CachedNetworkImage(
                  imageUrl: posts.length > 2 ? posts[2].previewUrl ?? '' : '',
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (context, url) => Container(color: Colors.grey[800]),
                  errorWidget: (context, url, error) => Container(color: Colors.grey[800]),
                ),
              ),
              const SizedBox(width: 1),
              Expanded(
                child: CachedNetworkImage(
                  imageUrl: posts.length > 3 ? posts[3].previewUrl ?? '' : '',
                  fit: BoxFit.cover,
                  height: double.infinity,
                  placeholder: (context, url) => Container(color: Colors.grey[800]),
                  errorWidget: (context, url, error) => Container(color: Colors.grey[800]),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

