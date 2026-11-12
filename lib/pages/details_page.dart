import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/collection_model.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../providers/boards_provider.dart';
import '../providers/ref_boards_provider.dart';
import '../widgets/save_to_board_sheet.dart';
import '../widgets/add_to_ref_sheet.dart';
import '../services/download_service.dart';
import '../services/e621_collections_api.dart';
import 'collection_detail_page.dart';
import 'gallery_page.dart';

/// Builds the Hero tag shared between a grid tile and the detail view.
/// Includes the index so duplicate posts in the same list never collide.
String postHeroTag(String prefix, int index, E621Post post) => '$prefix-$index-${post.id}';

bool _isVideoPost(E621Post post) => post.isVideo;

/// How decoded video frames reach the screen.
///
/// On Android the default `textureView` path hands the hardware decoder's YUV
/// buffers to Flutter's renderer (Impeller/Vulkan via ImageReader). On several
/// chipsets (notably MediaTek / Xiaomi devices) the decoder pads rows to a
/// vendor-specific stride that Flutter imports incorrectly, so any stream whose
/// size isn't perfectly aligned (e.g. e621's 1102x620 or 960x540 H.264
/// transcodes) renders as horizontal colour streaks while playback continues
/// normally, so no error is raised and no fallback can kick in.
///
/// `platformView` renders into a native `SurfaceView` that the Android system
/// compositor converts, which is the same path native video apps use, so frames
/// display correctly regardless of decoder stride or source resolution.
VideoViewType get _preferredVideoViewType =>
    (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
        ? VideoViewType.platformView
        : VideoViewType.textureView;

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

  /// Optional collections API client (useful for testing or custom clients).
  final E621CollectionsApi? collectionsApi;

  const PostDetailPage({
    super.key,
    this.post,
    this.posts,
    this.initialIndex,
    this.onLoadMore,
    this.heroTagPrefix,
    this.collectionsApi,
  }) : assert(post != null || (posts != null && posts.length > 0), 'Either post or non-empty posts must be provided.');

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late List<E621Post> _posts;
  late int _currentIndex;
  late PageController _pageController;
  Timer? _pageSettleTimer;
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
    _pageSettleTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// Pre-fetches the lightweight sample previews around [index] after a swipe
  /// settles so neighboring pages render on their very first frame without
  /// saturating bandwidth or image decoders with multi-megabyte originals.
  void _precacheNeighbors(int index) {
    if (!mounted) return;
    void ignoreError(Object _, StackTrace? _) {}

    for (final offset in const [1, -1, 2]) {
      final i = index + offset;
      if (i < 0 || i >= _posts.length) continue;
      final post = _posts[i];

      if (post.previewUrl != null) {
        precacheImage(CachedNetworkImageProvider(post.previewUrl!), context, onError: ignoreError);
      }
    }
  }

  void _onPageSettled() {
    _pageSettleTimer = null;
    if (!mounted || _currentIndex >= _posts.length) return;
    final post = currentPost;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (!post.isFavorited && !auth.isKnownFavorite(post.id)) {
      _checkIfFavorite(post);
    }
    _precacheNeighbors(_currentIndex);
  }

  void _onPageChanged(int index) {
    if (index >= _posts.length) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final nextPost = _posts[index];
    final knownFav = nextPost.isFavorited || auth.isKnownFavorite(nextPost.id);
    if (knownFav) {
      auth.markAsFavoriteLocally(nextPost.id);
    }
    setState(() {
      _currentIndex = index;
      _isFav = knownFav;
    });

    _pageSettleTimer?.cancel();
    _pageSettleTimer = Timer(const Duration(milliseconds: 150), _onPageSettled);

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
        setState(() {
          if (widget.posts != null) {
            _posts = List<E621Post>.from(widget.posts!);
          }
        });
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
        auth.host,
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
          Consumer<RefBoardsProvider>(
            builder: (context, refProvider, child) {
              final isInRef = refProvider.refBoards.any((b) => b.items.any((i) => i.postId == currentPost.id));
              return IconButton(
                icon: Icon(
                  isInRef ? Icons.draw : Icons.draw_outlined,
                  color: isInRef ? Colors.cyanAccent : null,
                ),
                tooltip: 'Add to Ref Canvas',
                onPressed: () => showAddToRefSheet(context, currentPost),
              );
            },
          ),
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
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Download Art',
            onPressed: () {
              final auth = Provider.of<AuthProvider>(context, listen: false);
              DownloadService.downloadWithFeedback(
                context,
                currentPost,
                authHeaders: auth.authHeaders,
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
        allowImplicitScrolling: true,
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
            collectionsApi: widget.collectionsApi,
            siblingPosts: _posts,
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
  final E621CollectionsApi? collectionsApi;
  final List<E621Post>? siblingPosts;

  const _PostContentView({
    super.key,
    required this.post,
    required this.isActive,
    this.heroTag,
    this.collectionsApi,
    this.siblingPosts,
  });

  @override
  State<_PostContentView> createState() => _PostContentViewState();
}

class _PostContentViewState extends State<_PostContentView> with WidgetsBindingObserver {
  VideoPlayerController? _videoController;
  Timer? _settleActivationTimer;
  late bool isVideo;
  int _videoInitToken = 0;
  int _currentVideoUrlIndex = 0;
  bool _videoError = false;
  bool _userPaused = false;
  bool _isMuted = false;
  bool _isRecoveringLoop = false;
  bool _poolsAndRelationsRequested = false;
  bool _allowFullResImage = false;
  bool _fullImageLoaded = false;
  Size _lastKnownVideoSize = Size.zero;
  Animation<double>? _routeAnimation;
  final Map<int, E621Collection> _resolvedPools = {};
  final Map<int, E621Post> _resolvedRelatedPosts = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    isVideo = _isVideoPost(widget.post);
    _seedSiblingPosts();
    if (widget.isActive) {
      _allowFullResImage = true;
      _loadPoolsAndRelationships();
    }
  }

  void _activateSettledMedia() {
    _settleActivationTimer?.cancel();
    _settleActivationTimer = null;
    if (!mounted || !widget.isActive) return;

    if (!_poolsAndRelationsRequested) {
      _loadPoolsAndRelationships();
    }

    if (isVideo) {
      if (_videoController == null && !_videoError && _canPlayInCurrentRoute) {
        _initVideo();
      } else if (_videoController != null &&
          _videoController!.value.isInitialized &&
          !_userPaused &&
          _canPlayInCurrentRoute) {
        _videoController!.play();
      }
    } else if (!_allowFullResImage) {
      setState(() {
        _allowFullResImage = true;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newRouteAnimation = ModalRoute.of(context)?.animation;
    if (_routeAnimation != newRouteAnimation) {
      _routeAnimation?.removeStatusListener(_onRouteAnimationStatusChanged);
      _routeAnimation = newRouteAnimation;
      _routeAnimation?.addStatusListener(_onRouteAnimationStatusChanged);
    }

    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final animStatus = _routeAnimation?.status;

    if (!tickerEnabled ||
        animStatus == AnimationStatus.reverse ||
        animStatus == AnimationStatus.dismissed) {
      // Another route covered this page or this route is being popped:
      // immediately release hardware video decoder resources.
      if (_videoController != null) {
        _disposeVideo(notify: false);
      }
      return;
    }

    if (isVideo &&
        widget.isActive &&
        _settleActivationTimer == null &&
        _videoController == null &&
        !_videoError &&
        (animStatus == null || animStatus == AnimationStatus.completed)) {
      _initVideo();
    }
  }

  void _onRouteAnimationStatusChanged(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.reverse || status == AnimationStatus.dismissed) {
      // Release video texture before reverse Hero transition flies back to grid.
      _disposeVideo(notify: true);
    } else if (status == AnimationStatus.completed) {
      if (isVideo &&
          widget.isActive &&
          _settleActivationTimer == null &&
          TickerMode.valuesOf(context).enabled &&
          _videoController == null &&
          !_videoError) {
        _initVideo();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      controller.pause();
    } else if (state == AppLifecycleState.resumed) {
      if (mounted && isVideo && widget.isActive && TickerMode.valuesOf(context).enabled) {
        if (controller.value.hasError) {
          _retryVideo();
        } else if (!_userPaused) {
          controller.play();
        }
      }
    }
  }

  bool get _canPlayInCurrentRoute {
    if (!mounted || !TickerMode.valuesOf(context).enabled) return false;
    final status = _routeAnimation?.status;
    return status == null || status == AnimationStatus.completed;
  }

  E621CollectionsApi _getApi() {
    if (widget.collectionsApi != null) return widget.collectionsApi!;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    return E621CollectionsApi(auth.authHeaders, host: auth.host);
  }

  void _seedSiblingPosts() {
    final siblings = widget.siblingPosts;
    if (siblings == null || siblings.isEmpty) return;
    final parentId = widget.post.parentId;
    final childrenSet = widget.post.childrenIds.toSet();
    for (final s in siblings) {
      if (s.id == parentId || childrenSet.contains(s.id)) {
        _resolvedRelatedPosts[s.id] = s;
      }
    }
  }

  Future<void> _loadPoolsAndRelationships() async {
    if (_poolsAndRelationsRequested) return;
    _poolsAndRelationsRequested = true;
    final post = widget.post;
    if (!post.hasPools && !post.hasRelationships) return;

    final api = _getApi();

    if (post.poolIds.isNotEmpty) {
      try {
        final pools = await api.getPoolsByIds(post.poolIds);
        if (mounted && widget.post.id == post.id && pools.isNotEmpty) {
          setState(() {
            for (final p in pools) {
              _resolvedPools[p.id] = p;
            }
          });
        }
      } catch (_) {}
    }

    final relatedIds = <int>[
      if (post.parentId != null) post.parentId!,
      ...post.childrenIds,
    ];
    if (relatedIds.isNotEmpty) {
      try {
        final postsMap = await api.getPostsByIds(relatedIds, requirePreview: false);
        if (mounted && widget.post.id == post.id && postsMap.isNotEmpty) {
          setState(() {
            _resolvedRelatedPosts.addAll(postsMap);
          });
        }
      } catch (_) {}
    }
  }

  void _disposeVideo({bool notify = false}) {
    _videoInitToken++;
    _isRecoveringLoop = false;
    _lastKnownVideoSize = Size.zero;
    final old = _videoController;
    _videoController = null;
    if (old != null) {
      old.dispose();
      if (notify && mounted) {
        setState(() {});
      }
    }
  }

  void _retryVideo() {
    if (!mounted) return;
    setState(() {
      _videoError = false;
      _userPaused = false;
      _currentVideoUrlIndex = 0;
    });
    _initVideo();
  }

  /// Switches to the next candidate stream (wrapping around). Lets the user
  /// escape a source whose hardware decode renders garbage without raising an
  /// error that would trigger the automatic fallback.
  void _nextVideoSource() {
    if (!mounted) return;
    final count = widget.post.playableVideoUrls.length;
    if (count < 2) return;
    _disposeVideo(notify: false);
    setState(() {
      _videoError = false;
      _userPaused = false;
      _currentVideoUrlIndex = (_currentVideoUrlIndex + 1) % count;
    });
    _initVideo();
  }

  Future<void> _initVideo() async {
    final urls = widget.post.playableVideoUrls;
    if (urls.isEmpty) return;
    if (_currentVideoUrlIndex >= urls.length) {
      _currentVideoUrlIndex = 0;
    }

    final int token = ++_videoInitToken;
    _isRecoveringLoop = false;
    _lastKnownVideoSize = Size.zero;
    final old = _videoController;
    _videoController = null;
    if (old != null) {
      old.dispose();
    }

    final String targetUrl = urls[_currentVideoUrlIndex];

    Map<String, String> headers = const {'User-Agent': 'SkerE621/1.0 (by anonymous on e621)'};
    try {
      headers = Provider.of<AuthProvider>(context, listen: false).authHeaders;
    } catch (_) {}

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(targetUrl),
      httpHeaders: headers,
      viewType: _preferredVideoViewType,
    );
    _videoController = controller;
    controller.addListener(() => _onVideoControllerUpdate(controller, token));

    try {
      await controller.initialize();
      if (!mounted || token != _videoInitToken || !widget.isActive) {
        if (_videoController == controller) {
          _videoController = null;
        }
        controller.dispose();
        return;
      }

      if (controller.value.hasError) {
        _handleVideoFailure(token);
        return;
      }

      await controller.setLooping(true);
      if (_isMuted) {
        await controller.setVolume(0.0);
      }

      if (!mounted || token != _videoInitToken || !widget.isActive) {
        if (_videoController == controller) {
          _videoController = null;
        }
        controller.dispose();
        return;
      }

      _lastKnownVideoSize = controller.value.size;
      setState(() {
        _videoError = false;
      });

      if (!_userPaused && _canPlayInCurrentRoute) {
        await controller.play();
      }
    } catch (_) {
      if (mounted && token == _videoInitToken) {
        _handleVideoFailure(token);
      } else {
        if (_videoController == controller) {
          _videoController = null;
        }
        controller.dispose();
      }
    }
  }

  void _onVideoControllerUpdate(VideoPlayerController controller, int token) {
    if (!mounted || token != _videoInitToken || _videoController != controller) return;
    final val = controller.value;

    if (val.hasError) {
      _handleVideoFailure(token);
      return;
    }

    if (!val.isInitialized) return;

    if (val.size != _lastKnownVideoSize && val.size != Size.zero) {
      _lastKnownVideoSize = val.size;
      setState(() {});
    }

    // Recover from WebM/ExoPlayer end-of-stream freeze (including when
    // VideoEventType.completed pauses and seeks to the last frame).
    if (!_userPaused &&
        !_isRecoveringLoop &&
        (val.isCompleted ||
            (!val.isPlaying &&
                !val.isBuffering &&
                val.duration > Duration.zero &&
                val.position >= val.duration - const Duration(milliseconds: 200)))) {
      _isRecoveringLoop = true;
      Future<void>.delayed(const Duration(milliseconds: 16)).then((_) {
        if (!mounted || token != _videoInitToken || _videoController != controller) return null;
        return controller.seekTo(Duration.zero);
      }).then((_) {
        if (mounted &&
            token == _videoInitToken &&
            _videoController == controller &&
            !_userPaused &&
            _canPlayInCurrentRoute) {
          return controller.play();
        }
        return null;
      }).whenComplete(() {
        _isRecoveringLoop = false;
      });
    }
  }

  void _handleVideoFailure(int token) {
    if (!mounted || token != _videoInitToken) return;
    final urls = widget.post.playableVideoUrls;
    _disposeVideo(notify: false);
    if (!widget.isActive) return;
    if (_currentVideoUrlIndex + 1 < urls.length) {
      _currentVideoUrlIndex++;
      _initVideo();
    } else {
      setState(() {
        _videoError = true;
      });
    }
  }

  Future<T?> _pushRoutePauseVideo<T>(BuildContext context, Route<T> route) async {
    if (isVideo) {
      _disposeVideo(notify: true);
    }
    final result = await Navigator.push<T>(context, route);
    if (mounted && isVideo && widget.isActive && _canPlayInCurrentRoute) {
      _videoError = false;
      _initVideo();
    }
    return result;
  }

  @override
  void didUpdateWidget(_PostContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id) {
      _settleActivationTimer?.cancel();
      _settleActivationTimer = null;
      _disposeVideo(notify: false);
      isVideo = _isVideoPost(widget.post);
      _currentVideoUrlIndex = 0;
      _videoError = false;
      _userPaused = false;
      _poolsAndRelationsRequested = false;
      _allowFullResImage = widget.isActive;
      _fullImageLoaded = false;
      _resolvedPools.clear();
      _resolvedRelatedPosts.clear();
      _seedSiblingPosts();
      if (widget.isActive) {
        _loadPoolsAndRelationships();
        if (isVideo && _canPlayInCurrentRoute) {
          _initVideo();
        }
      }
      return;
    }
    if (widget.isActive && !oldWidget.isActive) {
      if (isVideo) {
        _videoError = false;
      }
      _settleActivationTimer?.cancel();
      // Defer heavy media initialization (ExoPlayer / SurfaceView creation,
      // multi-megabyte full-res image download, and pool/relationship API calls)
      // by 100ms after a swipe crosses the halfway mark so the page finishes
      // sliding smoothly into place and rapid multi-page swipes never lag.
      _settleActivationTimer = Timer(const Duration(milliseconds: 100), _activateSettledMedia);
    } else if (!widget.isActive && oldWidget.isActive) {
      _settleActivationTimer?.cancel();
      _settleActivationTimer = null;
      if (isVideo) {
        // Release the native video decoder immediately when swiping past the
        // halfway mark so offscreen PageView items never starve MediaCodec instances.
        _disposeVideo(notify: true);
      }
    }
  }

  @override
  void dispose() {
    _settleActivationTimer?.cancel();
    _settleActivationTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatusChanged);
    _disposeVideo(notify: false);
    super.dispose();
  }

  Future<void> _openRelatedPost(
    BuildContext context,
    int postId, {
    List<int>? siblingIds,
  }) async {
    E621Post? target = _resolvedRelatedPosts[postId];
    if (target == null) {
      try {
        final map = await _getApi().getPostsByIds([postId], requirePreview: false);
        target = map[postId];
        if (target != null && mounted) {
          setState(() {
            _resolvedRelatedPosts[postId] = target!;
          });
        }
      } catch (_) {}
    }

    if (!context.mounted) return;

    if (target != null) {
      List<E621Post>? list;
      int initialIndex = 0;
      if (siblingIds != null && siblingIds.length > 1) {
        final resolvedList = siblingIds
            .map((id) => _resolvedRelatedPosts[id])
            .whereType<E621Post>()
            .toList();
        if (resolvedList.isNotEmpty) {
          list = resolvedList;
          final idx = resolvedList.indexWhere((p) => p.id == postId);
          if (idx >= 0) initialIndex = idx;
        }
      }
      await _pushRoutePauseVideo(
        context,
        MaterialPageRoute(
          builder: (context) => PostDetailPage(
            post: target,
            posts: list,
            initialIndex: initialIndex,
            collectionsApi: widget.collectionsApi,
          ),
        ),
      );
    } else {
      await _pushRoutePauseVideo(
        context,
        MaterialPageRoute(
          builder: (context) => E621GalleryPage(initialSearch: 'id:$postId'),
        ),
      );
    }
  }

  Widget _buildPoolsSection(BuildContext context) {
    if (widget.post.poolIds.isEmpty) return const SizedBox.shrink();
    const color = Colors.tealAccent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: Text(
            'Pools',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color),
          ),
        ),
        Wrap(
          spacing: 8.0,
          runSpacing: 6.0,
          children: widget.post.poolIds.map((poolId) {
            final pool = _resolvedPools[poolId];
            final hasName = pool != null && pool.displayName.trim().isNotEmpty;
            final pageIdx = pool != null ? pool.postIds.indexOf(widget.post.id) : -1;
            final totalPosts = pool != null
                ? (pool.postCount > 0 ? pool.postCount : pool.postIds.length)
                : 0;
            final String? progressLabel = (pageIdx >= 0 && totalPosts > 0)
                ? 'Page ${pageIdx + 1} of $totalPosts'
                : (totalPosts > 0 ? '$totalPosts posts' : null);
            final String? categoryBadge = pool == null
                ? null
                : (pool.isSeries ? 'SERIES' : 'COLLECTION');

            return Material(
              color: color.withValues(alpha: 0.14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: color.withValues(alpha: 0.45)),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  final targetPool = pool ??
                      E621Collection(
                        type: CollectionType.pool,
                        id: poolId,
                        name: 'Pool #$poolId',
                      );
                  _pushRoutePauseVideo(
                    context,
                    MaterialPageRoute(
                      builder: (context) => CollectionDetailPage(collection: targetPool),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        pool?.isSeries == true
                            ? Icons.auto_stories
                            : Icons.collections_bookmark_outlined,
                        size: 16,
                        color: color,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              hasName ? pool.displayName : 'Pool #$poolId',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            if (hasName || categoryBadge != null || progressLabel != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Wrap(
                                  spacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (categoryBadge != null)
                                      Text(
                                        categoryBadge,
                                        style: const TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                          color: color,
                                        ),
                                      ),
                                    if (progressLabel != null)
                                      Text(
                                        progressLabel,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: Colors.grey[300],
                                        ),
                                      ),
                                    if (hasName)
                                      Text(
                                        'Pool #$poolId',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey[400],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right, size: 16, color: Colors.white54),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildRelatedPostChip(
    BuildContext context, {
    required int postId,
    required String label,
    required bool isParent,
    required Color color,
    List<int>? siblingIds,
  }) {
    final related = _resolvedRelatedPosts[postId];
    final thumbUrl = related?.previewUrl;

    return Material(
      color: color.withValues(alpha: 0.14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openRelatedPost(context, postId, siblingIds: siblingIds),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (thumbUrl != null && thumbUrl.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: CachedNetworkImage(
                      imageUrl: thumbUrl,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(color: Colors.grey[850]),
                      errorWidget: (context, url, error) => Container(
                        color: Colors.grey[850],
                        child: Icon(
                          isParent ? Icons.subdirectory_arrow_left : Icons.subdirectory_arrow_right,
                          size: 14,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ] else ...[
                Icon(
                  isParent ? Icons.subdirectory_arrow_left : Icons.subdirectory_arrow_right,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: 6),
              ],
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  if (related != null && (related.rating.isNotEmpty || related.score != 0))
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        [
                          if (related.rating.isNotEmpty) related.rating.toUpperCase(),
                          if (related.score != 0) '↑ ${related.score}',
                        ].join(' • '),
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey[300],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRelationshipsSection(BuildContext context) {
    final parentId = widget.post.parentId;
    final childrenIds = widget.post.childrenIds;
    if (parentId == null && childrenIds.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parentId != null) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Text(
              'Parent Post',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.orangeAccent,
              ),
            ),
          ),
          _buildRelatedPostChip(
            context,
            postId: parentId,
            label: 'Parent #$parentId',
            isParent: true,
            color: Colors.orangeAccent,
          ),
        ],
        if (childrenIds.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Text(
              'Children Posts',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.cyanAccent,
              ),
            ),
          ),
          Wrap(
            spacing: 8.0,
            runSpacing: 6.0,
            children: childrenIds
                .map(
                  (childId) => _buildRelatedPostChip(
                    context,
                    postId: childId,
                    label: 'Child #$childId',
                    isParent: false,
                    color: Colors.cyanAccent,
                    siblingIds: childrenIds,
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildTagSection(BuildContext context, String title, List<String> tags, Color color) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final bgColor = color.withValues(alpha: 0.2);
    final borderColor = color.withValues(alpha: 0.5);
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
          runSpacing: 6.0,
          children: tags
              .map(
                (tag) => Material(
                  color: bgColor,
                  shape: StadiumBorder(side: BorderSide(color: borderColor)),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      _pushRoutePauseVideo(
                        context,
                        MaterialPageRoute(
                          builder: (context) => E621GalleryPage(initialSearch: tag),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text(
                        tag,
                        style: const TextStyle(fontSize: 10, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
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
    final loadFullRes = _fullImageLoaded || (widget.isActive && _allowFullResImage);
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildSample(),
        if (loadFullRes)
          CachedNetworkImage(
            imageUrl: fullUrl,
            // Decode at screen resolution instead of the original (often 4K+).
            memCacheWidth: _decodeWidthFor(context),
            fit: BoxFit.contain,
            fadeInDuration: const Duration(milliseconds: 150),
            fadeOutDuration: Duration.zero,
            imageBuilder: (context, imageProvider) {
              _fullImageLoaded = true;
              return Image(image: imageProvider, fit: BoxFit.contain);
            },
            placeholder: (context, url) => const Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.only(right: 10, bottom: 10),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
            // If the original fails, keep showing the sample underneath.
            errorWidget: (context, url, error) => const SizedBox.shrink(),
          )
        else if (widget.isActive)
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

  void _togglePlayPause() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      _userPaused = true;
      controller.pause();
    } else {
      _userPaused = false;
      controller.play();
    }
  }

  void _toggleMute() {
    final controller = _videoController;
    _isMuted = !_isMuted;
    if (controller != null && controller.value.isInitialized) {
      controller.setVolume(_isMuted ? 0.0 : 1.0);
    }
  }

  Widget _buildVideoMedia(BuildContext context) {
    if (_videoError) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildSample(fallback: const SizedBox.shrink()),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 28),
                  const SizedBox(height: 6),
                  const Text(
                    'Video failed to load',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: _retryVideo,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return _withLoadingBadge(_buildSample(fallback: const SizedBox.shrink()));
    }

    final rawAspect = controller.value.aspectRatio;
    final safeAspect = (rawAspect > 0 && rawAspect.isFinite) ? rawAspect : (16.0 / 9.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Keep preview sample behind the video surface to prevent black/static flashes
        // before the first frame renders or during loop seeks.
        _buildSample(fallback: const SizedBox.shrink()),
        Center(
          child: AspectRatio(
            aspectRatio: safeAspect,
            child: VideoPlayer(
              controller,
              key: ObjectKey(controller),
            ),
          ),
        ),
        _VideoControlsOverlay(
          controller: controller,
          onTogglePlayPause: _togglePlayPause,
          onToggleMute: _toggleMute,
          onReload: _retryVideo,
          onNextSource: widget.post.playableVideoUrls.length > 1 ? _nextVideoSource : null,
          sourceLabel: '${_currentVideoUrlIndex + 1}/${widget.post.playableVideoUrls.length}',
        ),
      ],
    );
  }

  Widget _buildMedia(BuildContext context) {
    final Widget media = isVideo ? _buildVideoMedia(context) : _buildImage(context);

    if (widget.heroTag == null) return media;
    return Hero(
      tag: widget.heroTag!,
      // Always use the lightweight static preview image during Hero flight
      // transitions so the native VideoPlayer Texture is never reparented into
      // the Overlay (which causes transition lag and surface texture glitches).
      flightShuttleBuilder: isVideo
          ? (flightContext, animation, flightDirection, fromHeroContext, toHeroContext) {
              return _buildSample(fallback: const SizedBox.shrink());
            }
          : null,
      child: media,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Column(
        children: [
          RepaintBoundary(
            child: Container(
              constraints: BoxConstraints(
                minHeight: 300,
                maxHeight: MediaQuery.of(context).size.height * 0.7,
              ),
              width: double.infinity,
              color: Colors.black,
              child: SizedBox.expand(child: _buildMedia(context)),
            ),
          ),
          RepaintBoundary(
            child: Column(
              children: [
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
                      _buildPoolsSection(context),
                      _buildRelationshipsSection(context),
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
          ),
        ],
      ),
    );
  }
}

class _VideoControlsOverlay extends StatelessWidget {
  final VideoPlayerController controller;
  final VoidCallback onTogglePlayPause;
  final VoidCallback onToggleMute;
  final VoidCallback onReload;
  final VoidCallback? onNextSource;
  final String sourceLabel;

  const _VideoControlsOverlay({
    required this.controller,
    required this.onTogglePlayPause,
    required this.onToggleMute,
    required this.onReload,
    this.onNextSource,
    this.sourceLabel = '',
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final isMuted = value.volume == 0.0;
        final isPlaying = value.isPlaying;
        final isBuffering = value.isBuffering;

        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onTogglePlayPause,
              child: Center(
                child: AnimatedOpacity(
                  opacity: (!isPlaying && !isBuffering) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
              ),
            ),
            if (isBuffering)
              const Positioned(
                right: 12,
                top: 12,
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            Positioned(
              right: 8,
              bottom: 14,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Material(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        isMuted ? Icons.volume_off : Icons.volume_up,
                        color: Colors.white,
                        size: 18,
                      ),
                      tooltip: isMuted ? 'Unmute' : 'Mute',
                      onPressed: onToggleMute,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (onNextSource != null) ...[
                    Material(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: const StadiumBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: onNextSource,
                        child: Tooltip(
                          message: 'Glitchy? Try another video source',
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.swap_horiz, color: Colors.white, size: 18),
                                const SizedBox(width: 4),
                                Text(
                                  sourceLabel,
                                  style: const TextStyle(color: Colors.white, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Material(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.replay,
                        color: Colors.white,
                        size: 18,
                      ),
                      tooltip: 'Reload Video',
                      onPressed: onReload,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                padding: const EdgeInsets.only(top: 6),
                colors: VideoProgressColors(
                  playedColor: Colors.blueAccent,
                  bufferedColor: Colors.white38,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}