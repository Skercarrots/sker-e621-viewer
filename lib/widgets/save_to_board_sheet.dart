import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/board_model.dart';
import '../models/post_model.dart';
import '../providers/boards_provider.dart';

Future<void> showSaveToBoardSheet(BuildContext context, E621Post post) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext sheetContext) {
      return SaveToBoardSheet(post: post);
    },
  );
}

class SaveToBoardSheet extends StatefulWidget {
  final E621Post post;

  const SaveToBoardSheet({super.key, required this.post});

  @override
  State<SaveToBoardSheet> createState() => _SaveToBoardSheetState();
}

class _SaveToBoardSheetState extends State<SaveToBoardSheet> {
  final TextEditingController _newBoardController = TextEditingController();

  @override
  void dispose() {
    _newBoardController.dispose();
    super.dispose();
  }

  void _showCreateBoardDialog(BuildContext context, BoardsProvider boardsProvider) {
    _newBoardController.clear();
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text('Create New Board'),
          content: TextField(
            controller: _newBoardController,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'e.g. Dragons, Favorites, Wallpapers',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) async {
              if (value.trim().isNotEmpty) {
                final newBoard = await boardsProvider.createBoard(
                  value.trim(),
                  initialPost: widget.post,
                );
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Created "${newBoard.name}" and saved art!')),
                  );
                }
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = _newBoardController.text.trim();
                if (name.isNotEmpty) {
                  final newBoard = await boardsProvider.createBoard(
                    name,
                    initialPost: widget.post,
                  );
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Created "${newBoard.name}" and saved art!')),
                    );
                  }
                }
              },
              child: const Text('Create & Save'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBoardThumbnail(Board board) {
    if (board.coverUrl != null && board.coverUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: board.coverUrl!,
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          placeholder: (context, url) => Container(
            width: 50,
            height: 50,
            color: Colors.grey[800],
          ),
          errorWidget: (context, url, error) => Container(
            width: 50,
            height: 50,
            color: Colors.grey[800],
            child: const Icon(Icons.folder, color: Colors.blueAccent),
          ),
        ),
      );
    }
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.folder_outlined, color: Colors.blueAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final boardsProvider = Provider.of<BoardsProvider>(context);
    final boards = boardsProvider.boards;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top Drag Handle
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  children: [
                    if (widget.post.previewUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CachedNetworkImage(
                          imageUrl: widget.post.previewUrl!,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Save to Board',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'File #${widget.post.id}',
                            style: TextStyle(color: Colors.grey[400], fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 24),

              // Create Board Action
              ListTile(
                leading: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.add,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                title: const Text(
                  'Create new board',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text('Add a custom collection'),
                onTap: () => _showCreateBoardDialog(context, boardsProvider),
              ),

              const Divider(height: 16),

              // Boards list
              if (boards.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.dashboard_customize_outlined,
                          size: 48,
                          color: Colors.grey[600],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'No boards created yet',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Tap "Create new board" above to start your first folder.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[400], fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: boards.length,
                    itemBuilder: (context, index) {
                      final board = boards[index];
                      final bool isSaved = board.postIds.contains(widget.post.id);

                      return ListTile(
                        leading: _buildBoardThumbnail(board),
                        title: Text(
                          board.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${board.postCount} ${board.postCount == 1 ? "art" : "arts"}',
                          style: TextStyle(color: Colors.grey[400], fontSize: 12),
                        ),
                        trailing: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isSaved
                                ? Colors.redAccent.withValues(alpha: 0.2)
                                : Theme.of(context).colorScheme.primary,
                            foregroundColor: isSaved ? Colors.redAccent : Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          icon: Icon(
                            isSaved ? Icons.check : Icons.bookmark_add,
                            size: 16,
                          ),
                          label: Text(isSaved ? 'Saved' : 'Save'),
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final wasSaved = isSaved;
                            await boardsProvider.togglePostInBoard(board.id, widget.post);
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  wasSaved
                                      ? 'Removed from "${board.name}"'
                                      : 'Saved to "${board.name}"!',
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                        onTap: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final wasSaved = isSaved;
                          await boardsProvider.togglePostInBoard(board.id, widget.post);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                wasSaved
                                    ? 'Removed from "${board.name}"'
                                    : 'Saved to "${board.name}"!',
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
