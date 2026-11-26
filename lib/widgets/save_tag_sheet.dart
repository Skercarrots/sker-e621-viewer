import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/favorite_tags_model.dart';
import '../pages/gallery_page.dart';
import '../providers/blacklist_provider.dart';
import '../providers/favorite_tags_provider.dart';

/// Opens the bottom sheet to save/manage a tag in Favorite Tags & Tag Sets.
Future<void> showSaveTagSheet(
  BuildContext context, {
  required String tag,
  int category = 0,
  ValueChanged<String>? onSearchTag,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext sheetContext) {
      return SaveTagSheet(
        tag: tag,
        category: category,
        onSearchTag: onSearchTag,
      );
    },
  );
}

class SaveTagSheet extends StatefulWidget {
  final String tag;
  final int category;
  final ValueChanged<String>? onSearchTag;

  const SaveTagSheet({
    super.key,
    required this.tag,
    this.category = 0,
    this.onSearchTag,
  });

  @override
  State<SaveTagSheet> createState() => _SaveTagSheetState();
}

class _SaveTagSheetState extends State<SaveTagSheet> {
  final TextEditingController _newSetController = TextEditingController();

  @override
  void dispose() {
    _newSetController.dispose();
    super.dispose();
  }

  FavoriteTagsProvider? _maybeFavoriteTags(BuildContext context) {
    try {
      return Provider.of<FavoriteTagsProvider>(context);
    } on ProviderNotFoundException {
      return null;
    }
  }

  BlacklistProvider? _maybeBlacklist(BuildContext context) {
    try {
      return Provider.of<BlacklistProvider>(context);
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _showSnack(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _createSetWithTag(
    BuildContext context,
    FavoriteTagsProvider favProvider,
    int resolvedCategory,
  ) async {
    _newSetController.clear();
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        Future<void> submit() async {
          final name = _newSetController.text.trim();
          if (name.isEmpty) return;
          final newSet = await favProvider.createSet(
            name,
            initialTag: widget.tag,
            initialTagCategory: resolvedCategory,
          );
          if (dialogContext.mounted) {
            Navigator.of(dialogContext).pop();
          }
          if (context.mounted) {
            _showSnack(context, 'Created "${newSet.name}" and added tag!');
          }
        }

        return AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text('Create Tag Set'),
          content: TextField(
            controller: _newSetController,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'e.g. Species, Favorite Artists, Combos',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: submit,
              child: const Text('Create & Add'),
            ),
          ],
        );
      },
    );
  }

  void _handleSearch(BuildContext context) {
    final normalized = FavoriteTag.normalizeName(widget.tag);
    final query = normalized.isEmpty ? widget.tag : normalized;
    final navigator = Navigator.of(context);
    navigator.pop();
    if (widget.onSearchTag != null) {
      widget.onSearchTag!(query);
    } else {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => E621GalleryPage(initialSearch: query),
        ),
      );
    }
  }

  Future<void> _handleCopy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: widget.tag));
    if (context.mounted) {
      _showSnack(context, 'Copied "${widget.tag}"');
    }
  }

  Future<void> _handleBlockToggle(
    BuildContext context,
    BlacklistProvider blacklistProvider,
  ) async {
    final normalized = FavoriteTag.normalizeName(widget.tag);
    if (normalized.isEmpty) return;

    if (blacklistProvider.hasExactRule(normalized)) {
      await blacklistProvider.removeExactRule(normalized);
      if (context.mounted) {
        _showSnack(context, 'Removed "$normalized" from blacklist');
      }
    } else {
      await blacklistProvider.addRule(normalized);
      if (context.mounted) {
        _showSnack(context, 'Added "$normalized" to blacklist');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final favProvider = _maybeFavoriteTags(context);
    final blacklistProvider = _maybeBlacklist(context);

    final normalizedTag = FavoriteTag.normalizeName(widget.tag);
    final existingTag = favProvider?.getTag(normalizedTag);
    final resolvedCategory = widget.category != 0
        ? widget.category
        : (existingTag?.category ?? FavoriteTag.inferCategory(normalizedTag));
    final categoryColor = FavoriteTag.colorForCategory(resolvedCategory);
    final categoryLabel = FavoriteTag.labelForCategory(resolvedCategory);
    final isSaved = favProvider?.isFavorite(normalizedTag) ?? false;
    final sets = favProvider?.sets ?? const <FavoriteTagSet>[];
    final isBlocked = blacklistProvider?.hasExactRule(normalizedTag) ?? false;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: ShapeDecoration(
                          color: categoryColor.withValues(alpha: 0.18),
                          shape: StadiumBorder(
                            side: BorderSide(
                              color: categoryColor.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isSaved) ...[
                              const Icon(
                                Icons.star_rounded,
                                size: 15,
                                color: Colors.amberAccent,
                              ),
                              const SizedBox(width: 5),
                            ],
                            Flexible(
                              child: Text(
                                widget.tag,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: categoryColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        categoryLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: categoryColor,
                        ),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 20, color: Colors.white12),

              // Quick Favorite toggle
              if (favProvider != null)
                ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: (isSaved ? Colors.amberAccent : Colors.grey[700]!)
                          .withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      isSaved ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: isSaved ? Colors.amberAccent : Colors.white70,
                    ),
                  ),
                  title: const Text(
                    'Favorite Tags',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    isSaved
                        ? 'Saved in your favorite tags'
                        : 'Save for quick access anytime',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  trailing: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isSaved
                          ? Colors.amberAccent.withValues(alpha: 0.2)
                          : Theme.of(context).colorScheme.primary,
                      foregroundColor:
                          isSaved ? Colors.amberAccent : Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    icon: Icon(
                      isSaved ? Icons.check : Icons.star_outline_rounded,
                      size: 16,
                    ),
                    label: Text(isSaved ? 'Saved' : 'Save'),
                    onPressed: () async {
                      final nowSaved = await favProvider.toggleFavoriteTag(
                        widget.tag,
                        category: resolvedCategory,
                      );
                      if (context.mounted) {
                        _showSnack(
                          context,
                          nowSaved
                              ? 'Saved "${widget.tag}" to favorites!'
                              : 'Removed "${widget.tag}" from favorites',
                        );
                      }
                    },
                  ),
                  onTap: () async {
                    final nowSaved = await favProvider.toggleFavoriteTag(
                      widget.tag,
                      category: resolvedCategory,
                    );
                    if (context.mounted) {
                      _showSnack(
                        context,
                        nowSaved
                            ? 'Saved "${widget.tag}" to favorites!'
                            : 'Removed "${widget.tag}" from favorites',
                      );
                    }
                  },
                ),

              if (favProvider != null) ...[
                const Divider(height: 16, color: Colors.white12),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'TAG SETS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                        color: Colors.grey[400],
                      ),
                    ),
                  ),
                ),
                ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.add,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  title: const Text(
                    'Create new tag set',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Organize tags into custom groups',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () =>
                      _createSetWithTag(context, favProvider, resolvedCategory),
                ),
                if (sets.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                    child: Text(
                      'No tag sets yet. Create one above to group related tags together.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[400], fontSize: 12.5),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: sets.length,
                      itemBuilder: (context, index) {
                        final set = sets[index];
                        final isInSet = set.tagNames.contains(normalizedTag);

                        return ListTile(
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Colors.grey[800],
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              isInSet ? Icons.label : Icons.label_outline,
                              color: isInSet
                                  ? Colors.cyanAccent
                                  : Colors.blueAccent,
                            ),
                          ),
                          title: Text(
                            set.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${set.tagCount} ${set.tagCount == 1 ? 'tag' : 'tags'}',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 12,
                            ),
                          ),
                          trailing: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isInSet
                                  ? Colors.cyanAccent.withValues(alpha: 0.18)
                                  : Theme.of(context).colorScheme.primary,
                              foregroundColor:
                                  isInSet ? Colors.cyanAccent : Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                            icon: Icon(
                              isInSet ? Icons.check : Icons.add,
                              size: 16,
                            ),
                            label: Text(isInSet ? 'Added' : 'Add'),
                            onPressed: () async {
                              final added = await favProvider.toggleTagInSet(
                                set.id,
                                widget.tag,
                                category: resolvedCategory,
                              );
                              if (context.mounted) {
                                _showSnack(
                                  context,
                                  added
                                      ? 'Added to "${set.name}"!'
                                      : 'Removed from "${set.name}"',
                                );
                              }
                            },
                          ),
                          onTap: () async {
                            final added = await favProvider.toggleTagInSet(
                              set.id,
                              widget.tag,
                              category: resolvedCategory,
                            );
                            if (context.mounted) {
                              _showSnack(
                                context,
                                added
                                    ? 'Added to "${set.name}"!'
                                    : 'Removed from "${set.name}"',
                              );
                            }
                          },
                        );
                      },
                    ),
                  ),
              ],

              const Divider(height: 16, color: Colors.white12),

              // Bottom quick actions
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.grey[700]!),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        icon: const Icon(Icons.search, size: 17),
                        label: const Text(
                          'Search',
                          style: TextStyle(fontSize: 12.5),
                        ),
                        onPressed: () => _handleSearch(context),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.grey[700]!),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        icon: const Icon(Icons.copy_outlined, size: 17),
                        label: const Text(
                          'Copy',
                          style: TextStyle(fontSize: 12.5),
                        ),
                        onPressed: () => _handleCopy(context),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              isBlocked ? Colors.redAccent : Colors.white70,
                          side: BorderSide(
                            color: isBlocked
                                ? Colors.redAccent
                                : Colors.grey[700]!,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        icon: const Icon(Icons.block, size: 17),
                        label: Text(
                          isBlocked ? 'Blocked' : 'Block',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        onPressed: blacklistProvider == null
                            ? null
                            : () =>
                                _handleBlockToggle(context, blacklistProvider),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
