import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/ref_board_model.dart';
import '../models/post_model.dart';
import '../providers/ref_boards_provider.dart';
import '../pages/ref_canvas_page.dart';

Future<void> showAddToRefSheet(BuildContext context, E621Post post) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext sheetContext) {
      return AddToRefSheet(post: post);
    },
  );
}

class AddToRefSheet extends StatefulWidget {
  final E621Post post;

  const AddToRefSheet({super.key, required this.post});

  @override
  State<AddToRefSheet> createState() => _AddToRefSheetState();
}

class _AddToRefSheetState extends State<AddToRefSheet> {
  final TextEditingController _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _showCreateCanvasDialog(BuildContext context, RefBoardsProvider provider) {
    _nameController.clear();
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text('Create New Ref Canvas'),
          content: TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'e.g. Pose Studies, Anatomy, Lighting',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) async {
              if (value.trim().isNotEmpty) {
                final newBoard = await provider.createRefBoard(
                  value.trim(),
                  initialPosts: [widget.post],
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (context.mounted) {
                  Navigator.pop(context);
                  _showSavedSnackbar(context, newBoard);
                }
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                final name = _nameController.text.trim();
                if (name.isNotEmpty) {
                  final newBoard = await provider.createRefBoard(
                    name,
                    initialPosts: [widget.post],
                  );
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (context.mounted) {
                    Navigator.pop(context);
                    _showSavedSnackbar(context, newBoard);
                  }
                }
              },
              child: const Text('Create & Pin'),
            ),
          ],
        );
      },
    );
  }

  void _showSavedSnackbar(BuildContext context, RefBoard board) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Pinned art #${widget.post.id} to "${board.name}"!'),
        action: SnackBarAction(
          label: 'OPEN CANVAS',
          textColor: Colors.cyanAccent,
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => RefCanvasPage(boardId: board.id)),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final refProvider = Provider.of<RefBoardsProvider>(context);
    final boards = refProvider.refBoards;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 4, bottom: 12),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 48,
                    height: 48,
                    color: Colors.grey[850],
                    child: CachedNetworkImage(
                      imageUrl: widget.post.previewUrl ?? '',
                      fit: BoxFit.cover,
                      errorWidget: (context, url, error) => const Icon(Icons.broken_image),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Add to Ref Canvas',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'File #${widget.post.id} • Select a canvas to pin',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18, color: Colors.cyanAccent),
                  label: const Text('New', style: TextStyle(color: Colors.cyanAccent)),
                  onPressed: () => _showCreateCanvasDialog(context, refProvider),
                ),
              ],
            ),
            const Divider(height: 24, color: Colors.white12),
            if (boards.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28.0),
                child: Column(
                  children: [
                    const Icon(Icons.draw_outlined, size: 48, color: Colors.cyanAccent),
                    const SizedBox(height: 12),
                    const Text(
                      'No Ref Canvases yet',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Create a Reference Canvas to start collecting drawing references.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.cyanAccent,
                        foregroundColor: Colors.black,
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Create Ref Canvas'),
                      onPressed: () => _showCreateCanvasDialog(context, refProvider),
                    ),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: boards.length,
                  itemBuilder: (context, index) {
                    final b = boards[index];
                    final hasPost = b.items.any((item) => item.postId == widget.post.id);

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          width: 44,
                          height: 44,
                          color: Colors.grey[800],
                          child: b.coverUrl != null
                              ? CachedNetworkImage(imageUrl: b.coverUrl!, fit: BoxFit.cover)
                              : const Icon(Icons.draw_outlined, color: Colors.cyanAccent),
                        ),
                      ),
                      title: Text(b.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${b.itemCount} refs'),
                      trailing: hasPost
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.cyanAccent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                'On Canvas',
                                style: TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            )
                          : ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.cyanAccent,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                minimumSize: Size.zero,
                              ),
                              onPressed: () async {
                                await refProvider.addPostToRefBoard(b.id, widget.post);
                                if (context.mounted) {
                                  Navigator.pop(context);
                                  _showSavedSnackbar(context, b);
                                }
                              },
                              child: const Text('Add'),
                            ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

