import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/board_model.dart';
import '../providers/boards_provider.dart';
import '../providers/ref_boards_provider.dart';
import 'details_page.dart';
import 'ref_canvas_page.dart';

class BoardDetailPage extends StatelessWidget {
  final String boardId;

  const BoardDetailPage({super.key, required this.boardId});

  void _showRenameDialog(BuildContext context, BoardsProvider boardsProvider, Board board) {
    final controller = TextEditingController(text: board.name);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text('Rename Board'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Board Name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final newName = controller.text.trim();
                if (newName.isNotEmpty) {
                  await boardsProvider.renameBoard(board.id, newName);
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteDialog(BuildContext context, BoardsProvider boardsProvider, Board board) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text('Delete Board?'),
          content: Text('Are you sure you want to delete "${board.name}"? This cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: () async {
                await boardsProvider.deleteBoard(board.id);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final boardsProvider = Provider.of<BoardsProvider>(context);
    final board = boardsProvider.getBoardById(boardId);

    if (board == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Board')),
        body: const Center(child: Text('Board not found.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(board.name),
            Text(
              '${board.postCount} ${board.postCount == 1 ? "art" : "arts"}',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.draw, color: Colors.cyanAccent),
            tooltip: 'Open as Reference Canvas',
            onPressed: () async {
              final refProvider = Provider.of<RefBoardsProvider>(context, listen: false);
              final refBoard = await refProvider.createFromSavedBoard(board);
              if (context.mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => RefCanvasPage(boardId: refBoard.id)),
                );
              }
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'open_ref') {
                final refProvider = Provider.of<RefBoardsProvider>(context, listen: false);
                final refBoard = await refProvider.createFromSavedBoard(board);
                if (context.mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => RefCanvasPage(boardId: refBoard.id)),
                  );
                }
              } else if (value == 'rename') {
                _showRenameDialog(context, boardsProvider, board);
              } else if (value == 'delete') {
                _showDeleteDialog(context, boardsProvider, board);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'open_ref',
                child: Row(
                  children: [
                    Icon(Icons.draw, color: Colors.cyanAccent, size: 20),
                    SizedBox(width: 8),
                    Text('Open as Ref Canvas'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'rename',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 20),
                    SizedBox(width: 8),
                    Text('Rename'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                    SizedBox(width: 8),
                    Text('Delete Board', style: TextStyle(color: Colors.redAccent)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: board.posts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.collections_bookmark_outlined,
                      size: 64,
                      color: Colors.grey[600],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'This board is empty',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Browse the gallery and tap the bookmark icon on any post to save it to "${board.name}".',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[400], fontSize: 14),
                    ),
                  ],
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(8.0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8.0,
                mainAxisSpacing: 8.0,
                childAspectRatio: 0.7,
              ),
              itemCount: board.posts.length,
              itemBuilder: (context, index) {
                final post = board.posts[index];
                final isVideo = post.extension == 'webm' || post.extension == 'mp4';

                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => PostDetailPage(
                          post: post,
                          posts: board.posts,
                          initialIndex: index,
                          heroTagPrefix: 'board-${board.id}',
                        ),
                      ),
                    );
                  },
                  onLongPress: () {
                    showModalBottomSheet<void>(
                      context: context,
                      backgroundColor: Colors.grey[850],
                      builder: (bottomSheetContext) {
                        return SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                leading: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                                title: const Text('Remove from this board'),
                                onTap: () async {
                                  Navigator.of(bottomSheetContext).pop();
                                  await boardsProvider.removePostFromBoard(board.id, post.id);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Removed File #${post.id} from "${board.name}"')),
                                    );
                                  }
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.open_in_new),
                                title: const Text('View post details'),
                                onTap: () {
                                  Navigator.of(bottomSheetContext).pop();
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => PostDetailPage(
                                        post: post,
                                        posts: board.posts,
                                        initialIndex: index,
                                        heroTagPrefix: 'board-${board.id}',
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Hero(
                        tag: postHeroTag('board-${board.id}', index, post),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8.0),
                          child: CachedNetworkImage(
                            imageUrl: post.previewUrl ?? '',
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Container(color: Colors.grey[850]),
                            errorWidget: (context, url, error) => const Icon(Icons.broken_image),
                          ),
                        ),
                      ),
                      if (isVideo)
                        const Positioned(
                          top: 6,
                          right: 6,
                          child: Icon(
                            Icons.movie,
                            color: Colors.white,
                            size: 20,
                            shadows: [
                              Shadow(
                                blurRadius: 4.0,
                                color: Colors.black54,
                                offset: Offset(1.0, 1.0),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
