import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../pages/settings_page.dart';
import '../providers/favorite_tags_provider.dart';
import '../services/tag_autocomplete_service.dart';
import 'favorite_tags_sheet.dart';

/// AppBar hamburger options menu providing quick access to Favorite Tags and Settings.
class AppOptionsMenuButton extends StatelessWidget {
  final ValueChanged<String>? onSearchTags;
  final TagAutocompleteService? autocompleteService;

  const AppOptionsMenuButton({
    super.key,
    this.onSearchTags,
    this.autocompleteService,
  });

  FavoriteTagsProvider? _maybeFavoriteTags(BuildContext context) {
    try {
      return Provider.of<FavoriteTagsProvider>(context);
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final favProvider = _maybeFavoriteTags(context);
    final totalCount = favProvider?.totalTagCount ?? 0;

    return PopupMenuButton<String>(
      icon: const Icon(Icons.menu),
      tooltip: 'Options',
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey[800]!),
      ),
      onSelected: (value) {
        if (value == 'favorites') {
          showFavoriteTagsSheet(
            context,
            onSearchTags: onSearchTags,
            autocompleteService: autocompleteService,
          );
        } else if (value == 'settings') {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsPage()),
          );
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'favorites',
          child: Row(
            children: [
              const Icon(
                Icons.star_outline_rounded,
                color: Colors.amberAccent,
                size: 20,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Favorite Tags',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              if (totalCount > 0) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amberAccent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$totalCount',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.amberAccent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem<String>(
          value: 'settings',
          child: Row(
            children: [
              Icon(Icons.settings_outlined, size: 20),
              SizedBox(width: 12),
              Text(
                'Settings',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
