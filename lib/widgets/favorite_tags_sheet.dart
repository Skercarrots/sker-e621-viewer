import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/favorite_tags_model.dart';
import '../pages/gallery_page.dart';
import '../providers/favorite_tags_provider.dart';
import '../services/tag_autocomplete_service.dart';
import 'save_tag_sheet.dart';
import 'tag_search_bar.dart';

/// Opens the Favorite Tags & Tag Sets modal bottom sheet.
Future<void> showFavoriteTagsSheet(
  BuildContext context, {
  ValueChanged<String>? onSearchTags,
  TagAutocompleteService? autocompleteService,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext sheetContext) {
      return FavoriteTagsSheet(
        onSearchTags: onSearchTags,
        autocompleteService: autocompleteService,
      );
    },
  );
}

class FavoriteTagsSheet extends StatefulWidget {
  final ValueChanged<String>? onSearchTags;
  final TagAutocompleteService? autocompleteService;

  const FavoriteTagsSheet({
    super.key,
    this.onSearchTags,
    this.autocompleteService,
  });

  @override
  State<FavoriteTagsSheet> createState() => _FavoriteTagsSheetState();
}

class _FavoriteTagsSheetState extends State<FavoriteTagsSheet> {
  final TextEditingController _addTagController = TextEditingController();
  final Map<String, int> _suggestedCategories = {};

  String? _selectedSetId;
  bool _isAddingTag = false;
  bool _isMultiSelectMode = false;
  final List<String> _selectedTags = [];

  @override
  void dispose() {
    _addTagController.dispose();
    super.dispose();
  }

  FavoriteTagsProvider? _maybeFavoriteTags(BuildContext context) {
    try {
      return Provider.of<FavoriteTagsProvider>(context);
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

  void _runSearch(BuildContext context, String rawQuery) {
    final query = rawQuery.trim();
    if (query.isEmpty) return;

    final navigator = Navigator.of(context);
    navigator.pop();
    if (widget.onSearchTags != null) {
      widget.onSearchTags!(query);
    } else {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => E621GalleryPage(initialSearch: query),
        ),
      );
    }
  }

  Future<void> _submitNewTags(
    BuildContext context,
    FavoriteTagsProvider provider,
    FavoriteTagSet? activeSet,
  ) async {
    final tokens = _addTagController.text
        .trim()
        .split(RegExp(r'\s+'))
        .map(FavoriteTag.normalizeName)
        .where((t) => t.isNotEmpty)
        .toList();

    if (tokens.isEmpty) return;

    int addedCount = 0;
    for (final tag in tokens) {
      final cat = _suggestedCategories[tag] ?? FavoriteTag.inferCategory(tag);
      if (activeSet != null) {
        final added = await provider.addTagToSet(
          activeSet.id,
          tag,
          category: cat,
        );
        if (added) addedCount++;
      } else {
        final added = await provider.addTag(tag, category: cat);
        if (added) addedCount++;
      }
    }

    _addTagController.clear();
    if (!context.mounted) return;

    if (activeSet != null) {
      _showSnack(
        context,
        addedCount > 0
            ? 'Added $addedCount ${addedCount == 1 ? 'tag' : 'tags'} to "${activeSet.name}"'
            : 'Already in "${activeSet.name}"',
      );
    } else {
      _showSnack(
        context,
        addedCount > 0
            ? 'Saved $addedCount ${addedCount == 1 ? 'tag' : 'tags'} to favorites'
            : 'Already in Favorite Tags',
      );
    }
  }

  Future<void> _showCreateSetDialog(
    BuildContext context,
    FavoriteTagsProvider provider,
  ) async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        Future<void> submit() async {
          final name = controller.text.trim();
          if (name.isEmpty) return;
          final created = await provider.createSet(name);
          if (dialogContext.mounted) {
            Navigator.of(dialogContext).pop();
          }
          if (mounted) {
            setState(() {
              _selectedSetId = created.id;
            });
          }
        }

        return AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text('Create Tag Set'),
          content: TextField(
            controller: controller,
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
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    controller.dispose();
  }

  Future<void> _showRenameSetDialog(
    BuildContext context,
    FavoriteTagsProvider provider,
    FavoriteTagSet set,
  ) async {
    final controller = TextEditingController(text: set.name);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        Future<void> submit() async {
          final name = controller.text.trim();
          if (name.isEmpty) return;
          await provider.renameSet(set.id, name);
          if (dialogContext.mounted) {
            Navigator.of(dialogContext).pop();
          }
        }

        return AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text('Rename Tag Set'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
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
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );
    controller.dispose();
  }

  Future<void> _showDeleteSetDialog(
    BuildContext context,
    FavoriteTagsProvider provider,
    FavoriteTagSet set,
  ) async {
    bool removeExclusive = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.grey[850],
              title: Text('Delete "${set.name}"?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This will remove the tag set. Your tags stay in Favorite Tags unless you choose to remove exclusive tags below.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: removeExclusive,
                    title: const Text(
                      'Also remove tags only in this set',
                      style: TextStyle(fontSize: 13),
                    ),
                    onChanged: (val) {
                      setDialogState(() {
                        removeExclusive = val ?? false;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                  onPressed: () async {
                    await provider.deleteSet(
                      set.id,
                      removeExclusiveTags: removeExclusive,
                    );
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                    if (mounted) {
                      setState(() {
                        _selectedSetId = null;
                      });
                    }
                  },
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _toggleTagSelection(String tagName) {
    setState(() {
      if (_selectedTags.contains(tagName)) {
        _selectedTags.remove(tagName);
      } else {
        _selectedTags.add(tagName);
      }
    });
  }

  Widget _buildSetFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
    Color? accentColor,
  }) {
    final color = accentColor ?? Colors.blueAccent;
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: Material(
        color: selected
            ? color.withValues(alpha: 0.24)
            : Colors.grey[850],
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? color : Colors.grey[700]!,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 14,
                    color: selected ? color : Colors.white70,
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                    color: selected ? Colors.white : Colors.grey[300],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagChip(BuildContext sheetContext, FavoriteTag tag) {
    final color = tag.categoryColor;
    final isSelected = _isMultiSelectMode && _selectedTags.contains(tag.name);

    return Material(
      color: isSelected
          ? Colors.cyanAccent.withValues(alpha: 0.25)
          : color.withValues(alpha: 0.18),
      shape: StadiumBorder(
        side: BorderSide(
          color: isSelected ? Colors.cyanAccent : color.withValues(alpha: 0.55),
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (_isMultiSelectMode) {
            _toggleTagSelection(tag.name);
          } else {
            _runSearch(sheetContext, tag.name);
          }
        },
        onLongPress: _isMultiSelectMode
            ? null
            : () {
                HapticFeedback.mediumImpact();
                showSaveTagSheet(
                  sheetContext,
                  tag: tag.name,
                  category: tag.category,
                  onSearchTag: (selected) {
                    if (sheetContext.mounted) {
                      _runSearch(sheetContext, selected);
                    }
                  },
                );
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isMultiSelectMode) ...[
                Icon(
                  isSelected ? Icons.check_circle : Icons.circle_outlined,
                  size: 14,
                  color: isSelected ? Colors.cyanAccent : Colors.white54,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                tag.name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = _maybeFavoriteTags(context);
    if (provider == null) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Center(
            child: Text('Favorite tags are unavailable in this context.'),
          ),
        ),
      );
    }

    final sets = provider.sets;
    final activeSet =
        _selectedSetId != null ? provider.getSetById(_selectedSetId!) : null;
    if (_selectedSetId != null && activeSet == null) {
      _selectedSetId = null;
    }

    final displayedTags = activeSet != null
        ? provider.getTagsForSet(activeSet.id)
        : provider.tags;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82,
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
              const SizedBox(height: 8),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  children: [
                    const Icon(
                      Icons.star_rounded,
                      color: Colors.amberAccent,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Favorite Tags',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${provider.totalTagCount}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[300],
                        ),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        Icons.checklist_rounded,
                        color: _isMultiSelectMode
                            ? Colors.cyanAccent
                            : Colors.white70,
                      ),
                      tooltip: 'Combine tags',
                      onPressed: () {
                        setState(() {
                          _isMultiSelectMode = !_isMultiSelectMode;
                          if (!_isMultiSelectMode) {
                            _selectedTags.clear();
                          }
                        });
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        _isAddingTag ? Icons.remove : Icons.add,
                        color: _isAddingTag ? Colors.cyanAccent : Colors.white,
                      ),
                      tooltip: 'Add tag',
                      onPressed: () {
                        setState(() {
                          _isAddingTag = !_isAddingTag;
                        });
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),

              // Collapsible inline Add Tag panel
              if (_isAddingTag)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TagSearchBar(
                          controller: _addTagController,
                          hintText: activeSet != null
                              ? 'Add tag to "${activeSet.name}"'
                              : 'Add tag (e.g. dragon)',
                          autocompleteService: widget.autocompleteService,
                          onSuggestionSelected: (suggestion) {
                            _suggestedCategories[
                                    FavoriteTag.normalizeName(suggestion.name)] =
                                suggestion.category;
                          },
                          onSubmitted: (_) =>
                              _submitNewTags(context, provider, activeSet),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 45),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onPressed: () =>
                            _submitNewTags(context, provider, activeSet),
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ),

              // Horizontal Tag Sets strip
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  children: [
                    _buildSetFilterChip(
                      label: 'All (${provider.totalTagCount})',
                      selected: activeSet == null,
                      onTap: () {
                        setState(() {
                          _selectedSetId = null;
                        });
                      },
                    ),
                    for (final set in sets)
                      _buildSetFilterChip(
                        label: '${set.name} (${set.tagCount})',
                        selected: activeSet?.id == set.id,
                        accentColor: Colors.cyanAccent,
                        onTap: () {
                          setState(() {
                            _selectedSetId = set.id;
                          });
                        },
                      ),
                    _buildSetFilterChip(
                      label: '+ New Set',
                      selected: false,
                      accentColor: Colors.amberAccent,
                      onTap: () => _showCreateSetDialog(context, provider),
                    ),
                  ],
                ),
              ),

              // Selected set toolbar
              if (activeSet != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey[800]!),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.label_outline,
                        size: 16,
                        color: Colors.cyanAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${activeSet.name} • ${activeSet.tagCount} ${activeSet.tagCount == 1 ? 'tag' : 'tags'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.cyanAccent,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        icon: const Icon(Icons.search, size: 16),
                        label: const Text(
                          'Search All',
                          style: TextStyle(fontSize: 12),
                        ),
                        onPressed: activeSet.tagNames.isEmpty
                            ? null
                            : () => _runSearch(
                                  context,
                                  provider.buildQueryForSet(activeSet.id),
                                ),
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(
                          Icons.more_vert,
                          size: 18,
                          color: Colors.white70,
                        ),
                        color: Colors.grey[850],
                        padding: EdgeInsets.zero,
                        onSelected: (action) {
                          if (action == 'rename') {
                            _showRenameSetDialog(context, provider, activeSet);
                          } else if (action == 'delete') {
                            _showDeleteSetDialog(context, provider, activeSet);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'rename',
                            child: Row(
                              children: [
                                Icon(Icons.edit_outlined, size: 18),
                                SizedBox(width: 10),
                                Text('Rename Set'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                  color: Colors.redAccent,
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'Delete Set',
                                  style: TextStyle(color: Colors.redAccent),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

              const Divider(height: 14, color: Colors.white12),

              // Tags body
              if (displayedTags.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 28,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.star_border_rounded,
                        size: 46,
                        color: Colors.grey[600],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        activeSet != null
                            ? 'This tag set is empty'
                            : 'No favorite tags yet',
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Long-press any tag on a post or tap + above to add tags.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[400], fontSize: 12.5),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.cyanAccent,
                          side: const BorderSide(color: Colors.cyanAccent),
                        ),
                        icon: const Icon(Icons.add, size: 17),
                        label: const Text('Add Tag'),
                        onPressed: () {
                          setState(() {
                            _isAddingTag = true;
                          });
                        },
                      ),
                    ],
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8.0,
                        runSpacing: 8.0,
                        children: displayedTags
                            .map((tag) => _buildTagChip(context, tag))
                            .toList(),
                      ),
                    ),
                  ),
                ),

              // Footer: either Multi-Select bar or subtle hint
              if (_isMultiSelectMode)
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    border: const Border(
                      top: BorderSide(color: Colors.white12),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selectedTags.isEmpty
                              ? 'Tap tags to combine'
                              : _selectedTags.join(' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: _selectedTags.isEmpty
                                ? Colors.grey[400]
                                : Colors.white,
                          ),
                        ),
                      ),
                      if (_selectedTags.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _selectedTags.clear();
                            });
                          },
                          child: const Text('Clear'),
                        ),
                      const SizedBox(width: 6),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.cyanAccent,
                          foregroundColor: Colors.black,
                        ),
                        icon: const Icon(Icons.search, size: 17),
                        label: Text('Search (${_selectedTags.length})'),
                        onPressed: _selectedTags.isEmpty
                            ? null
                            : () => _runSearch(context, _selectedTags.join(' ')),
                      ),
                    ],
                  ),
                )
              else if (displayedTags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    'Tap a tag to search • Long-press to manage',
                    style: TextStyle(color: Colors.grey[500], fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
