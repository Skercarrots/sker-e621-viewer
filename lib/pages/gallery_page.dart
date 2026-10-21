import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import '../models/post_model.dart';
import 'details_page.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/blacklist_provider.dart';
import 'settings_page.dart';

class E621GalleryPage extends StatefulWidget {
  final String? initialSearch; // NEW: Accepts an initial search query
  const E621GalleryPage({super.key, this.initialSearch});

  @override
  State<E621GalleryPage> createState() => _E621GalleryPageState();
}

class _E621GalleryPageState extends State<E621GalleryPage> {
  final List<E621Post> _posts = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = false;
  int _page = 1;
  String _currentTags = '';

  /// Unique per gallery instance (several galleries can be alive at once).
  late final String _heroTagPrefix = 'gallery-${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    
    // NEW: Check if an initial search was passed from a tag click
    if (widget.initialSearch != null && widget.initialSearch!.isNotEmpty) {
      _currentTags = widget.initialSearch!;
      _searchController.text = widget.initialSearch!;
    }
    
    _fetchPosts();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
        _fetchPosts();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _startSearch(String query) {
    setState(() {
      _posts.clear();
      _page = 1;
      _currentTags = query;
    });
    _fetchPosts();
  }

  Future<void> _fetchPosts() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    try {
      final String searchTags = _currentTags.trim().isEmpty ? 'rating:s order:score' : _currentTags.trim();

      final uri = Uri.https(
        'e621.net',
        '/posts.json',
        {
          'tags': searchTags,
          'page': '$_page',
          'limit': '20',
          'v2': 'true',
          'mode': 'extended',
        },
      );
      
      final response = await http.get(uri, headers: authProvider.authHeaders);

      if (response.statusCode == 200) {
        final dynamic data = json.decode(response.body);
        final List<dynamic> postsJson = (data is List)
            ? data
            : (data is Map && data['posts'] is List ? data['posts'] as List<dynamic> : []);
        final newPosts = postsJson
            .whereType<Map<String, dynamic>>()
            .map((json) => E621Post.fromJson(json))
            .where((post) => post.previewUrl != null)
            .toList();

        for (final post in newPosts) {
          if (post.isFavorited) {
            authProvider.markAsFavoriteLocally(post.id);
          }
        }

        setState(() {
          _posts.addAll(newPosts);
          _page++;
          _isLoading = false;
        });

        // If a high percentage of items was filtered by blacklist on page 1, fetch next batch
        if (mounted) {
          final bl = Provider.of<BlacklistProvider>(context, listen: false);
          final visibleCount = bl.filterPosts(_posts).length;
          if (visibleCount < 10 && _page <= 4 && newPosts.isNotEmpty) {
            _fetchPosts();
          }
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      debugPrint('Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final blacklist = Provider.of<BlacklistProvider>(context);
    final visiblePosts = blacklist.filterPosts(_posts, isPool: false);

    return Scaffold(
      appBar: AppBar(
        title: Container(
          height: 45,
          decoration: BoxDecoration(color: Colors.grey[800], borderRadius: BorderRadius.circular(8)),
          child: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
               hintText: 'Search (ex: dragon order:score)',
              border: InputBorder.none,
              prefixIcon: Icon(Icons.search),
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
            onSubmitted: _startSearch,
          ),
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
        centerTitle: true,
      ),
      body: visiblePosts.isEmpty
          ? (_isLoading
              ? const Center(child: CircularProgressIndicator())
              : (_posts.isNotEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.block, size: 48, color: Colors.grey),
                          const SizedBox(height: 12),
                          Text(
                            'All ${_posts.length} posts hidden by blacklist.',
                            style: const TextStyle(color: Colors.grey, fontSize: 15),
                          ),
                          const SizedBox(height: 14),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.grey[850],
                              foregroundColor: Colors.cyanAccent,
                            ),
                            icon: const Icon(Icons.tune),
                            label: const Text('Manage Blacklist in Settings'),
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const SettingsPage()),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const Center(child: Text("No results."))))
          : GridView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(8.0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8.0,
                mainAxisSpacing: 8.0,
                childAspectRatio: 0.7,
              ),
              itemCount: visiblePosts.length + (_isLoading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == visiblePosts.length) return const Center(child: CircularProgressIndicator());

                final post = visiblePosts[index];
                final isVideo = post.extension == 'webm' || post.extension == 'mp4';

                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => PostDetailPage(
                        post: post,
                        posts: visiblePosts,
                        initialIndex: index,
                        onLoadMore: _fetchPosts,
                        heroTagPrefix: _heroTagPrefix,
                      ),
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand, 
                    children: [
                      Hero(
                        tag: postHeroTag(_heroTagPrefix, index, post),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8.0),
                          child: CachedNetworkImage(
                            imageUrl: post.previewUrl!,
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