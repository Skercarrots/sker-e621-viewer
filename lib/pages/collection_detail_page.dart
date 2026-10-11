import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/collection_model.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../providers/follows_provider.dart';
import '../services/e621_collections_api.dart';
import 'details_page.dart';

class CollectionDetailPage extends StatefulWidget {
  final E621Collection collection;

  const CollectionDetailPage({
    super.key,
    required this.collection,
  });

  @override
  State<CollectionDetailPage> createState() => _CollectionDetailPageState();
}

class _CollectionDetailPageState extends State<CollectionDetailPage> {
  late E621Collection _collection;
  late final String _heroTagPrefix =
      'col-${widget.collection.type.name}-${widget.collection.id}-${identityHashCode(this)}';

  final List<E621Post> _posts = [];
  final ScrollController _scrollController = ScrollController();

  bool _isLoading = false;
  bool _hasMore = true;
  int _page = 1;
  static const int _pageSize = 30;

  // For pools: the list of post ids in order
  List<int> _poolPostIds = [];
  int _poolOffset = 0;

  bool _isDescriptionExpanded = false;

  @override
  void initState() {
    super.initState();
    _collection = widget.collection;
    _poolPostIds = List<int>.from(_collection.postIds);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final follows = Provider.of<FollowsProvider>(context, listen: false);
      follows.markSeen(_collection.type, _collection.id, _collection.postCount);
    });

    _initFetch();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 300) {
        _fetchMorePosts();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initFetch() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders);

    // If pool has no postIds, fetch the full pool details first
    if (_collection.isPool && _poolPostIds.isEmpty) {
      final fresh = await api.getPool(_collection.id);
      if (fresh != null && mounted) {
        setState(() {
          _collection = fresh;
          _poolPostIds = List<int>.from(fresh.postIds);
        });
        final follows = Provider.of<FollowsProvider>(context, listen: false);
        if (follows.isFollowing(_collection.type, _collection.id)) {
          follows.updateCollectionInfo(fresh);
        }
      }
    }

    _fetchMorePosts();
  }

  Future<void> _fetchMorePosts() async {
    if (_isLoading || !_hasMore) return;
    setState(() => _isLoading = true);

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders);

    try {
      List<E621Post> newPosts = [];

      if (_collection.isPool) {
        if (_poolOffset >= _poolPostIds.length) {
          setState(() {
            _hasMore = false;
            _isLoading = false;
          });
          return;
        }

        final end = (_poolOffset + _pageSize).clamp(0, _poolPostIds.length);
        final chunk = _poolPostIds.sublist(_poolOffset, end);
        _poolOffset = end;

        newPosts = await api.getPostsInOrder(chunk);
        if (_poolOffset >= _poolPostIds.length) {
          _hasMore = false;
        }
      } else {
        // Post Set
        final shortname = _collection.shortname;
        if (shortname == null || shortname.isEmpty) {
          setState(() {
            _hasMore = false;
            _isLoading = false;
          });
          return;
        }

        newPosts = await api.getSetPosts(shortname, page: _page, limit: _pageSize);
        if (newPosts.length < _pageSize) {
          _hasMore = false;
        }
        _page++;
      }

      if (mounted) {
        setState(() {
          _posts.addAll(newPosts);
          _isLoading = false;
        });

        // If coverUrl is still empty and we found posts, set cover from first post
        if (_collection.coverUrl == null && _posts.isNotEmpty && _posts.first.previewUrl != null) {
          final updated = _collection.copyWith(coverUrl: _posts.first.previewUrl);
          _collection = updated;
          final follows = Provider.of<FollowsProvider>(context, listen: false);
          if (follows.isFollowing(updated.type, updated.id)) {
            follows.updateCollectionInfo(updated);
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching collection posts: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _openReader(int initialIndex) {
    if (_posts.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PostDetailPage(
          post: _posts[initialIndex],
          posts: _posts,
          initialIndex: initialIndex,
          onLoadMore: _hasMore ? _fetchMorePosts : null,
          heroTagPrefix: _heroTagPrefix,
        ),
      ),
    );
  }

  Color _badgeColor() {
    if (!_collection.isPool) return Colors.amberAccent;
    if (_collection.category == 'series') return Colors.blueAccent;
    return Colors.purpleAccent;
  }

  String _badgeLabel() {
    if (!_collection.isPool) return 'SET';
    if (_collection.category == 'series') return 'SERIES';
    if (_collection.category == 'collection') return 'COLLECTION';
    return 'POOL';
  }

  Widget _buildHeader(BuildContext context) {
    final follows = Provider.of<FollowsProvider>(context);
    final isFollowed = follows.isFollowing(_collection.type, _collection.id);

    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(bottom: BorderSide(color: Colors.grey[850]!, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Cover Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 80,
                  height: 110,
                  child: (_collection.coverUrl != null && _collection.coverUrl!.isNotEmpty)
                      ? CachedNetworkImage(
                          imageUrl: _collection.coverUrl!,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(color: Colors.grey[800]),
                          errorWidget: (context, url, error) => Container(
                            color: Colors.grey[800],
                            child: const Icon(Icons.broken_image, color: Colors.grey),
                          ),
                        )
                      : Container(
                          color: Colors.grey[800],
                          child: Icon(
                            _collection.isPool ? Icons.collections_bookmark : Icons.folder,
                            color: Colors.grey[600],
                            size: 32,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 14),

              // Title and metadata
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Badge category
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: _badgeColor().withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: _badgeColor().withValues(alpha: 0.6), width: 1),
                          ),
                          child: Text(
                            _badgeLabel(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: _badgeColor(),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        if (_collection.isActive) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.greenAccent.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.6), width: 1),
                            ),
                            child: const Text(
                              'ONGOING',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                                color: Colors.greenAccent,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Title
                    Text(
                      _collection.displayName,
                      style: const TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),

                    // Stats & Creator
                    Text(
                      '${_collection.postCount} arts'
                      '${_collection.creatorName != null && _collection.creatorName!.isNotEmpty ? " • by ${_collection.creatorName}" : ""}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.grey[400],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Action buttons: "Read / Start" and "Follow"
          Row(
            children: [
              if (_collection.isSeries) ...[
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.auto_stories, size: 18),
                    label: const Text(
                      'Read Series',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                    ),
                    onPressed: _posts.isNotEmpty ? () => _openReader(0) : null,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isFollowed ? Colors.redAccent : Colors.white,
                    side: BorderSide(
                      color: isFollowed ? Colors.redAccent : Colors.grey[700]!,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: Icon(
                    isFollowed ? Icons.favorite : Icons.favorite_border,
                    size: 18,
                    color: isFollowed ? Colors.redAccent : Colors.white70,
                  ),
                  label: Text(
                    isFollowed ? 'Following' : 'Follow',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                  ),
                  onPressed: () async {
                    final nowFollowed = await follows.toggleFollow(_collection);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            nowFollowed
                                ? 'Following "${_collection.displayName}"'
                                : 'Unfollowed "${_collection.displayName}"',
                          ),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                ),
              ),
            ],
          ),

          // Description (collapsible if long)
          if (_collection.description.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () {
                setState(() {
                  _isDescriptionExpanded = !_isDescriptionExpanded;
                });
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey[850],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[800]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _collection.description.trim(),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.grey[300],
                        height: 1.4,
                      ),
                      maxLines: _isDescriptionExpanded ? null : 3,
                      overflow: _isDescriptionExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                    ),
                    if (_collection.description.trim().length > 120) ...[
                      const SizedBox(height: 4),
                      Text(
                        _isDescriptionExpanded ? 'Show less' : 'Read more...',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _collection.displayName,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          _buildHeader(context),
          Expanded(
            child: _posts.isEmpty && _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _posts.isEmpty
                    ? Center(
                        child: Text(
                          'No posts found.',
                          style: TextStyle(color: Colors.grey[400]),
                        ),
                      )
                    : GridView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(8.0),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8.0,
                          mainAxisSpacing: 8.0,
                          childAspectRatio: 0.7,
                        ),
                        itemCount: _posts.length + (_isLoading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _posts.length) {
                            return const Center(child: CircularProgressIndicator());
                          }

                          final post = _posts[index];
                          final isVideo = post.extension == 'webm' || post.extension == 'mp4';

                          return GestureDetector(
                            onTap: () => _openReader(index),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Hero(
                                  tag: postHeroTag(_heroTagPrefix, index, post),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8.0),
                                    child: CachedNetworkImage(
                                      imageUrl: post.previewUrl ?? '',
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(color: Colors.grey[850]),
                                      errorWidget: (context, url, error) => Container(
                                        color: Colors.grey[850],
                                        child: const Icon(Icons.broken_image, color: Colors.grey),
                                      ),
                                    ),
                                  ),
                                ),

                                // Reading order pill for series (#1, #2, ...)
                                if (_collection.isSeries)
                                  Positioned(
                                    top: 6,
                                    left: 6,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.7),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: Colors.white24,
                                          width: 0.5,
                                        ),
                                      ),
                                      child: Text(
                                        '#${index + 1}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
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
                                      size: 18,
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
          ),
        ],
      ),
    );
  }
}

