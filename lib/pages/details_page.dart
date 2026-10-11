import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../providers/boards_provider.dart';
import '../widgets/save_to_board_sheet.dart';
import 'gallery_page.dart';

/// Builds the Hero tag shared between a grid tile and the detail view.
/// Includes the index so duplicate posts in the same list never collide.
String postHeroTag(String prefix, int index, E621Post post) => '$prefix-$index-${post.id}';

bool _isVideoPost(E621Post post) => post.extension == 'webm' || post.extension == 'mp4';

/// Width (in physical pixels) used to decode full-size images. Decoding
/// a 4K original at screen resolution saves a lot of memory and jank.
/// Must be the same value for precaching and displaying so the
/// in-memory ImageCache entry is reused.
int _decodeWidthFor(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final dpr = MediaQuery.devicePixelRatioOf(context);
  return (size.width * dpr).round();
}

class PostDetailPage extends StatefulWidget {
  final E621Post? post;
  final List<E621Post>? posts;
  final int? initialIndex;
  final Future<void> Function()? onLoadMore;

  /// When set, the image is wrapped in a [Hero] tagged with
  /// [postHeroTag] so it animates from the tapped grid tile.
  final String? heroTagPrefix;

  const PostDetailPage({
    super.key,
    this.post,
    this.posts,
    this.initialIndex,
    this.onLoadMore,
    this.heroTagPrefix,
  }) : assert(post != null || (posts != null && posts.length > 0), 'Either post or non-empty posts must be provided.');

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late List<E621Post> _posts;
  late int _currentIndex;
  late PageController _pageController;
  bool _isFav = false;
  bool _isLoadingMore = false;

  E621Post get currentPost => _posts[_currentIndex];

  @override
  void initState() {
    super.initState();
    if (widget.posts != null && widget.posts!.isNotEmpty) {
      _posts = List<E621Post>.from(widget.posts!);
      final initial = widget.initialIndex ?? (widget.post != null ? _posts.indexOf(widget.post!) : 0);
      _currentIndex = (initial >= 0 && initial < _posts.length) ? initial : 0;
    } else if (widget.post != null) {
      _posts = [widget.post!];
      _currentIndex = 0;
    } else {
      _posts = [];
      _currentIndex = 0;
    }
    _pageController = PageController(initialPage: _currentIndex);

    _updateFavoriteStatusForCurrentPost();

    // MediaQuery isn't safe to read in initState, so wait for the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheNeighbors(_currentIndex));
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Starts downloading/decoding the posts around [index] so swiping
  /// to them is instant. Uses exactly the same providers as
  /// [_PostContentView] so the in-memory cache entries are reused.
  void _precacheNeighbors(int index) {
    if (!mounted) return;
    final decodeWidth = _decodeWidthFor(context);
    void ignoreError(Object _, StackTrace? _) {}

    for (final offset in const [1, -1, 2]) {
      final i = index + offset;
      if (i < 0 || i >= _posts.length) continue;
      final post = _posts[i];

      if (post.previewUrl != null) {
        precacheImage(CachedNetworkImageProvider(post.previewUrl!), context, onError: ignoreError);
      }
      if (!_isVideoPost(post) && post.fileUrl != null && post.fileUrl != post.previewUrl) {
        precacheImage(
          ResizeImage.resizeIfNeeded(decodeWidth, null, CachedNetworkImageProvider(post.fileUrl!)),
          context,
          onError: ignoreError,
        );
      }
    }
  }

  void _onPageChanged(int index) {
    if (index >= _posts.length) return;
    setState(() {
      _currentIndex = index;
    });
    _updateFavoriteStatusForCurrentPost();
    _precacheNeighbors(index);

    // Trigger loading more items when nearing the end of the list
    if (widget.onLoadMore != null && index >= _posts.length - 3 && !_isLoadingMore) {
      _triggerLoadMore();
    }
  }

  Future<void> _triggerLoadMore() async {
    if (_isLoadingMore || widget.onLoadMore == null) return;
    setState(() => _isLoadingMore = true);
    try {
      await widget.onLoadMore!();
      if (mounted) {
        if (widget.posts != null) {
          _posts = widget.posts!;
        }
        _precacheNeighbors(_currentIndex);
      }
    } catch (e) {
      debugPrint('Error loading more in PostDetailPage: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  void _updateFavoriteStatusForCurrentPost() {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (currentPost.isFavorited || auth.isKnownFavorite(currentPost.id)) {
      if (mounted) setState(() => _isFav = true);
      auth.markAsFavoriteLocally(currentPost.id);
    } else {
      if (mounted) setState(() => _isFav = false);
      _checkIfFavorite(currentPost);
    }
  }

  Future<void> _checkIfFavorite(E621Post post) async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.isGuestMode) {
      final favs = await auth.getGuestFavorites();
      if (mounted && currentPost.id == post.id) {
        setState(() => _isFav = favs.any((p) => p.id == post.id));
      }
    } else if (auth.isLoggedIn && auth.user != null) {
      final uri = Uri.https(
        'e621.net',
        '/posts.json',
        {
          'tags': 'fav:${auth.user!.name} id:${post.id}',
          'v2': 'true',
        },
      );
      try {
        final response = await http.get(uri, headers: auth.authHeaders);
        if (response.statusCode == 200) {
          final dynamic data = jsonDecode(response.body);
          final List<dynamic> posts = (data is List)
              ? data
              : (data is Map && data['posts'] is List ? data['posts'] as List<dynamic> : []);
          if (posts.isNotEmpty) {
            auth.markAsFavoriteLocally(post.id);
            if (mounted && currentPost.id == post.id) {
              setState(() => _isFav = true);
            }
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _toggleFavorite() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final postToToggle = currentPost;

    if (!auth.isLoggedIn && !auth.isGuestMode) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text("Log in or use Guest Mode to save favorites.")),
      );
      return;
    }

    final currentFavState = _isFav;
    setState(() {
      _isFav = !currentFavState;
    });

    bool success = false;
    if (auth.isGuestMode) {
      success = await auth.toggleGuestFavorite(postToToggle, currentFavState);
    } else if (auth.isLoggedIn) {
      success = await auth.toggleApiFavorite(postToToggle.id, currentFavState);
    }

    if (!success) {
      if (mounted && currentPost.id == postToToggle.id) {
        setState(() => _isFav = currentFavState);
      }
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text("Failed to alter favorite status. Check connection.")),
      );
    } else {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(!currentFavState ? "Favorited!" : "Removed favorite!"),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('File #${currentPost.id}'),
            if (_posts.length > 1)
              Text(
                '${_currentIndex + 1} of ${_posts.length}',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[400],
                  fontWeight: FontWeight.normal,
                ),
              ),
          ],
        ),
        actions: [
          Consumer<BoardsProvider>(
            builder: (context, boardsProvider, child) {
              final isSaved = boardsProvider.getBoardsContainingPost(currentPost.id).isNotEmpty;
              return IconButton(
                icon: Icon(
                  isSaved ? Icons.bookmark : Icons.bookmark_add_outlined,
                  color: isSaved ? Colors.amberAccent : null,
                ),
                tooltip: 'Save to Board',
                onPressed: () => showSaveToBoardSheet(context, currentPost),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _toggleFavorite,
        child: Icon(
          _isFav ? Icons.favorite : Icons.favorite_border,
          color: _isFav ? Colors.redAccent : null,
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: _posts.length + (_isLoadingMore ? 1 : 0),
        onPageChanged: _onPageChanged,
        physics: const BouncingScrollPhysics(),
        itemBuilder: (context, index) {
          if (index == _posts.length) {
            return const Center(child: CircularProgressIndicator());
          }
          final post = _posts[index];
          return _PostContentView(
            key: ValueKey(post.id),
            post: post,
            isActive: index == _currentIndex,
            heroTag: widget.heroTagPrefix != null ? postHeroTag(widget.heroTagPrefix!, index, post) : null,
          );
        },
      ),
    );
  }
}

class _PostContentView extends StatefulWidget {
  final E621Post post;
  final bool isActive;
  final String? heroTag;

  const _PostContentView({
    super.key,
    required this.post,
    required this.isActive,
    this.heroTag,
  });

  @override
  State<_PostContentView> createState() => _PostContentViewState();
}

class _PostContentViewState extends State<_PostContentView> {
  VideoPlayerController? _videoController;
  late bool isVideo;

  @override
  void initState() {
    super.initState();
    isVideo = _isVideoPost(widget.post);
    if (isVideo && widget.isActive) {
      _initVideo();
    }
  }

  void _initVideo() {
    if (widget.post.fileUrl == null) return;
    _videoController = VideoPlayerController.networkUrl(Uri.parse(widget.post.fileUrl!))
      ..initialize().then((_) {
        if (mounted) {
          setState(() {});
          if (widget.isActive) {
            _videoController!.play();
            _videoController!.setLooping(true);
          }
        }
      });
  }

  @override
  void didUpdateWidget(_PostContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (isVideo) {
      if (widget.isActive && !oldWidget.isActive) {
        if (_videoController == null) {
          _initVideo();
        } else if (_videoController!.value.isInitialized) {
          _videoController!.play();
        }
      } else if (!widget.isActive && oldWidget.isActive) {
        _videoController?.pause();
      }
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Widget _buildTagSection(BuildContext context, String title, List<String> tags, Color color) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text(
            title,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color),
          ),
        ),
        Wrap(
          spacing: 8.0,
          runSpacing: 4.0,
          children: tags.map(
            (tag) => ActionChip(
              label: Text(tag, style: const TextStyle(fontSize: 10, color: Colors.white)),
              backgroundColor: color.withValues(alpha: 0.2),
              shape: StadiumBorder(side: BorderSide(color: color.withValues(alpha: 0.5))),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => E621GalleryPage(initialSearch: tag),
                  ),
                );
              },
            ),
          ).toList(),
        ),
      ],
    );
  }

  /// Sample image (same URL/provider as the grid thumbnail), so it's
  /// normally already in the in-memory cache and renders on frame one.
  Widget _buildSample({Widget? fallback}) {
    final sampleUrl = widget.post.previewUrl;
    final spinner = fallback ?? const Center(child: CircularProgressIndicator());
    if (sampleUrl == null) return spinner;
    return CachedNetworkImage(
      imageUrl: sampleUrl,
      fit: BoxFit.contain,
      fadeInDuration: Duration.zero,
      placeholder: (context, url) => spinner,
      errorWidget: (context, url, error) => fallback ?? const Center(child: Icon(Icons.error)),
    );
  }

  /// Small spinner in the corner signalling that the HD version is loading.
  Widget _withLoadingBadge(Widget child) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        const Positioned(
          right: 10,
          bottom: 10,
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ],
    );
  }

  Widget _buildImage(BuildContext context) {
    final fullUrl = widget.post.fileUrl;
    if (fullUrl == null || fullUrl == widget.post.previewUrl) {
      return _buildSample();
    }
    return CachedNetworkImage(
      imageUrl: fullUrl,
      // Decode at screen resolution instead of the original (often 4K+).
      memCacheWidth: _decodeWidthFor(context),
      fit: BoxFit.contain,
      fadeInDuration: const Duration(milliseconds: 150),
      fadeOutDuration: const Duration(milliseconds: 150),
      placeholder: (context, url) => _withLoadingBadge(_buildSample()),
      // If the original fails, keep showing the sample instead of an error.
      errorWidget: (context, url, error) => _buildSample(),
    );
  }

  Widget _buildMedia(BuildContext context) {
    final Widget media;
    if (isVideo) {
      media = (_videoController != null && _videoController!.value.isInitialized)
          ? Center(
              child: AspectRatio(
                aspectRatio: _videoController!.value.aspectRatio,
                child: VideoPlayer(_videoController!),
              ),
            )
          : _withLoadingBadge(_buildSample(fallback: const SizedBox.shrink()));
    } else {
      media = _buildImage(context);
    }

    if (widget.heroTag == null) return media;
    return Hero(tag: widget.heroTag!, child: media);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Column(
        children: [
          Container(
            constraints: BoxConstraints(
              minHeight: 300,
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            width: double.infinity,
            color: Colors.black,
            child: SizedBox.expand(child: _buildMedia(context)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
            child: Row(
              children: [
                if (widget.post.score != 0) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.arrow_upward, size: 14, color: Colors.greenAccent),
                        const SizedBox(width: 4),
                        Text(
                          '${widget.post.score}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (widget.post.rating.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.post.rating.toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: widget.post.rating.toLowerCase() == 'e'
                            ? Colors.redAccent
                            : widget.post.rating.toLowerCase() == 'q'
                                ? Colors.amberAccent
                                : Colors.greenAccent,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Consumer<BoardsProvider>(
                  builder: (context, boardsProvider, child) {
                    final boardsWithPost = boardsProvider.getBoardsContainingPost(widget.post.id);
                    final isSaved = boardsWithPost.isNotEmpty;
                    return OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isSaved ? Colors.amberAccent : Colors.white,
                        side: BorderSide(
                          color: isSaved ? Colors.amberAccent : Colors.grey[700]!,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: Icon(
                        isSaved ? Icons.bookmark : Icons.bookmark_add_outlined,
                        size: 16,
                      ),
                      label: Text(
                        isSaved ? '${boardsWithPost.length} Boards' : 'Save to Board',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () => showSaveToBoardSheet(context, widget.post),
                    );
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTagSection(context, 'Artists', widget.post.artistTags, Colors.redAccent),
                _buildTagSection(context, 'Characters', widget.post.characterTags, Colors.greenAccent),
                _buildTagSection(context, 'Copyrights', widget.post.copyrightTags, Colors.purpleAccent),
                _buildTagSection(context, 'Species', widget.post.speciesTags, Colors.amberAccent),
                _buildTagSection(context, 'General Tags', widget.post.generalTags, Colors.blueAccent),
                if (widget.post.description.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    "Description",
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white70),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey[800]!),
                    ),
                    child: Text(
                      widget.post.description,
                      style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
                    ),
                  ),
                ],
                const SizedBox(height: 80),
              ],
            ),
          ),
        ],
      ),
    );
  }
}