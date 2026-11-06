import 'package:flutter/material.dart';
import '../models/collection_filters.dart';

/// Search header shared by the Pools and Sets tabs.
///
/// Layout (top to bottom):
///  1. Search field with a "search options" button (badge = active filters).
///  2. Type segments (pools only) + sort button.
///  3. Dismissible chips for the advanced filters currently applied.
///
/// Everything that is rarely needed (search scope, status, creator, minimum
/// posts) lives in a bottom sheet, so the screen stays clean.
class CollectionSearchHeader extends StatelessWidget {
  final TextEditingController controller;
  final CollectionFilters filters;
  final bool isPool;

  /// Called whenever the typed text changes (to refresh the clear button etc.).
  final VoidCallback onTextChanged;

  /// Called when the query should be searched (submit or clear).
  final VoidCallback onSearch;

  /// Called with the new filters; the page should store them and reload.
  final ValueChanged<CollectionFilters> onFiltersChanged;

  const CollectionSearchHeader({
    super.key,
    required this.controller,
    required this.filters,
    required this.isPool,
    required this.onTextChanged,
    required this.onSearch,
    required this.onFiltersChanged,
  });

  String get _noun => isPool ? 'pools' : 'sets';

  String get _hint {
    if (filters.hasDefaultScope) return 'Search $_noun by name…';
    return 'Search ${filters.scopeLabel.toLowerCase()}…';
  }

  Future<void> _openOptions(BuildContext context) async {
    final result = await showCollectionFiltersSheet(
      context,
      initial: filters,
      isPool: isPool,
    );
    if (result != null) {
      onFiltersChanged(result.normalized(isPool: isPool));
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Column(
      children: [
        // 1. Search field
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: filters.hasAdvanced ? primary.withValues(alpha: 0.6) : Colors.grey[800]!,
              ),
            ),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 12, right: 2),
                  child: Icon(Icons.search, size: 20, color: Colors.grey),
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: 14),
                    onChanged: (_) => onTextChanged(),
                    onSubmitted: (_) => onSearch(),
                    decoration: InputDecoration(
                      hintText: _hint,
                      hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13.5),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    ),
                  ),
                ),
                if (controller.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                    tooltip: 'Clear',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      controller.clear();
                      onTextChanged();
                      onSearch();
                    },
                  ),
                Container(width: 1, height: 22, color: Colors.grey[800]),
                _OptionsButton(
                  count: filters.advancedCount,
                  onTap: () => _openOptions(context),
                ),
              ],
            ),
          ),
        ),

        // 2. Type + sort
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(
            children: [
              if (isPool) ...[
                _Segments<String?>(
                  options: const [
                    (null, 'All'),
                    ('series', 'Series'),
                    ('collection', 'Collections'),
                  ],
                  selected: filters.category,
                  onSelected: (v) => onFiltersChanged(filters.copyWith(category: v)),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Align(
                  alignment: isPool ? Alignment.centerRight : Alignment.centerLeft,
                  child: _SortButton(
                    filters: filters,
                    isPool: isPool,
                    onChanged: onFiltersChanged,
                  ),
                ),
              ),
            ],
          ),
        ),

        // 3. Active advanced filters
        if (filters.hasAdvanced) _ActiveFilters(
          filters: filters,
          onChanged: onFiltersChanged,
          onTap: () => _openOptions(context),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header pieces
// ---------------------------------------------------------------------------

class _OptionsButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _OptionsButton({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: 'Search options',
      child: InkWell(
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(14)),
        onTap: onTap,
        child: SizedBox(
          width: 50,
          height: 46,
          child: Center(
            child: Badge(
              isLabelVisible: count > 0,
              label: Text('$count'),
              backgroundColor: primary,
              textColor: Colors.white,
              child: Icon(
                Icons.tune,
                size: 21,
                color: count > 0 ? primary : Colors.grey[400],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact pill-shaped segmented control.
class _Segments<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  const _Segments({
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey[800]!),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, label) in options)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelected(value),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  color: value == selected ? primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: value == selected ? FontWeight.bold : FontWeight.normal,
                    color: value == selected ? Colors.white : Colors.grey[400],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

const Map<String, IconData> _orderIcons = {
  'updated_at': Icons.update,
  'created_at': Icons.fiber_new_outlined,
  'post_count': Icons.photo_library_outlined,
  'fav_count': Icons.favorite_border,
  'keyword_posts': Icons.sell_outlined,
  'name': Icons.sort_by_alpha,
};

class _SortButton extends StatelessWidget {
  final CollectionFilters filters;
  final bool isPool;
  final ValueChanged<CollectionFilters> onChanged;

  const _SortButton({
    required this.filters,
    required this.isPool,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final options = isPool ? CollectionOrder.pools : CollectionOrder.sets;
    final current = options.firstWhere(
      (o) => o.value == filters.order,
      orElse: () => options.first,
    );

    return PopupMenuButton<String>(
      tooltip: 'Sort by',
      initialValue: filters.order,
      position: PopupMenuPosition.under,
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey[800]!),
      ),
      onSelected: (v) => onChanged(
        filters.copyWith(
          order: v,
          inPosts: v == 'keyword_posts' ? true : filters.inPosts,
        ),
      ),
      itemBuilder: (context) => [
        for (final o in options)
          PopupMenuItem<String>(
            value: o.value,
            child: Row(
              children: [
                Icon(
                  _orderIcons[o.value] ?? Icons.sort,
                  size: 19,
                  color: o.value == filters.order ? primary : Colors.grey[400],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        o.label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: o.value == filters.order ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                      Text(
                        o.hint,
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
                if (o.value == filters.order) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check, size: 18, color: primary),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.grey[800]!),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_orderIcons[current.value] ?? Icons.sort, size: 16, color: Colors.grey[400]),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                current.shortLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey[300]),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: Colors.grey[500]),
          ],
        ),
      ),
    );
  }
}

class _ActiveFilters extends StatelessWidget {
  final CollectionFilters filters;
  final ValueChanged<CollectionFilters> onChanged;
  final VoidCallback onTap;

  const _ActiveFilters({
    required this.filters,
    required this.onChanged,
    required this.onTap,
  });

  Widget _chip(BuildContext context, IconData icon, String label, VoidCallback onDeleted) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InputChip(
        avatar: Icon(icon, size: 15, color: primary),
        label: Text(label, style: const TextStyle(fontSize: 11.5)),
        onPressed: onTap,
        onDeleted: onDeleted,
        deleteIconColor: Colors.grey[400],
        backgroundColor: primary.withValues(alpha: 0.12),
        side: BorderSide(color: primary.withValues(alpha: 0.4)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = filters;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        children: [
          if (!f.hasDefaultScope)
            _chip(
              context,
              Icons.manage_search,
              'In: ${f.scopeLabel}',
              () => onChanged(f.copyWith(inName: true, inDescription: false, inPosts: false)),
            ),
          if (f.isActive != null)
            _chip(
              context,
              f.isActive! ? Icons.autorenew : Icons.check_circle_outline,
              f.isActive! ? 'Active' : 'Completed',
              () => onChanged(f.copyWith(isActive: null)),
            ),
          if (f.creator.trim().isNotEmpty)
            _chip(
              context,
              Icons.person_outline,
              'By ${f.creator.trim()}',
              () => onChanged(f.copyWith(creator: '')),
            ),
          if (f.minPosts > 0)
            _chip(
              context,
              Icons.photo_library_outlined,
              '${f.minPosts}+ posts',
              () => onChanged(f.copyWith(minPosts: 0)),
            ),
          TextButton(
            onPressed: () => onChanged(f.clearAdvanced()),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Reset', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Options bottom sheet
// ---------------------------------------------------------------------------

/// Opens the "Search options" sheet. Resolves with the new filters when the
/// user taps "Show results", or `null` if it is dismissed.
Future<CollectionFilters?> showCollectionFiltersSheet(
  BuildContext context, {
  required CollectionFilters initial,
  required bool isPool,
}) {
  return showModalBottomSheet<CollectionFilters>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _FiltersSheet(initial: initial, isPool: isPool),
  );
}

class _FiltersSheet extends StatefulWidget {
  final CollectionFilters initial;
  final bool isPool;
  const _FiltersSheet({required this.initial, required this.isPool});

  @override
  State<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends State<_FiltersSheet> {
  late CollectionFilters _f = widget.initial;
  late final TextEditingController _creator = TextEditingController(text: widget.initial.creator);

  @override
  void dispose() {
    _creator.dispose();
    super.dispose();
  }

  String get _noun => widget.isPool ? 'pool' : 'set';

  bool get _canReset => _f.hasAdvanced || _creator.text.trim().isNotEmpty;

  void _toggleScope({bool? name, bool? description, bool? posts}) {
    final next = _f.copyWith(
      inName: name ?? _f.inName,
      inDescription: description ?? _f.inDescription,
      inPosts: posts ?? _f.inPosts,
    );
    // At least one place has to be searched.
    if (!next.inName && !next.inDescription && !next.inPosts) return;
    setState(() => _f = next);
  }

  void _apply() {
    Navigator.pop(context, _f.copyWith(creator: _creator.text.trim()));
  }

  String get _scopeHelp {
    if (_f.inPosts) {
      return 'Finds ${_noun}s through the tags of the posts inside them. '
          'Supports e621 syntax, e.g. dragon -gore rating:s';
    }
    if (_f.inDescription) return 'Also searches the $_noun description.';
    return 'Matches the $_noun name only.';
  }

  Widget _section(String title, Widget child, {String? help}) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.4,
              color: Colors.grey[400],
            ),
          ),
          const SizedBox(height: 8),
          child,
          if (help != null) ...[
            const SizedBox(height: 6),
            Text(help, style: TextStyle(fontSize: 11.5, height: 1.35, color: Colors.grey[500])),
          ],
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return FilterChip(
      avatar: icon == null
          ? null
          : Icon(icon, size: 16, color: selected ? Colors.white : Colors.grey[400]),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          color: selected ? Colors.white : Colors.grey[300],
        ),
      ),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
      selectedColor: primary,
      backgroundColor: Colors.grey[850],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      side: BorderSide(color: selected ? Colors.transparent : Colors.grey[800]!),
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Search options',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  onPressed: _canReset
                      ? () => setState(() {
                            _f = _f.clearAdvanced();
                            _creator.clear();
                          })
                      : null,
                  child: const Text('Reset'),
                ),
              ],
            ),

            _section(
              'SEARCH IN',
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _chip(
                    label: 'Name',
                    icon: Icons.title,
                    selected: _f.inName,
                    onTap: () => _toggleScope(name: !_f.inName),
                  ),
                  _chip(
                    label: 'Description',
                    icon: Icons.notes,
                    selected: _f.inDescription,
                    onTap: () => _toggleScope(description: !_f.inDescription),
                  ),
                  _chip(
                    label: 'Post tags',
                    icon: Icons.sell_outlined,
                    selected: _f.inPosts,
                    onTap: () => _toggleScope(posts: !_f.inPosts),
                  ),
                ],
              ),
              help: _scopeHelp,
            ),

            if (widget.isPool)
              _section(
                'STATUS',
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _chip(
                      label: 'Any',
                      selected: _f.isActive == null,
                      onTap: () => setState(() => _f = _f.copyWith(isActive: null)),
                    ),
                    _chip(
                      label: 'Active',
                      icon: Icons.autorenew,
                      selected: _f.isActive == true,
                      onTap: () => setState(() => _f = _f.copyWith(isActive: true)),
                    ),
                    _chip(
                      label: 'Completed',
                      icon: Icons.check_circle_outline,
                      selected: _f.isActive == false,
                      onTap: () => setState(() => _f = _f.copyWith(isActive: false)),
                    ),
                  ],
                ),
                help: 'Active pools are still receiving new posts.',
              ),

            _section(
              'MINIMUM POSTS',
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final n in CollectionFilters.minPostsChoices)
                    _chip(
                      label: n == 0 ? 'Any' : '$n+',
                      selected: _f.minPosts == n,
                      onTap: () => setState(() => _f = _f.copyWith(minPosts: n)),
                    ),
                ],
              ),
            ),

            _section(
              'CREATED BY',
              TextField(
                controller: _creator,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _apply(),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Username',
                  hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13.5),
                  prefixIcon: const Icon(Icons.person_outline, size: 20),
                  suffixIcon: _creator.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(_creator.clear),
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.grey[850],
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey[800]!),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey[800]!),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _apply,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Show results', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
