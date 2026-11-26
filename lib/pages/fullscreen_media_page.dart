import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../services/download_service.dart';
import '../widgets/zoomable_image_view.dart';
import 'details_page.dart';

/// Mutable handoff carrier allowing [PostDetailPage] and [FullscreenMediaPage]
/// to transfer a live [VideoPlayerController] without re-buffering or creating
/// duplicate native video surfaces.
class FullscreenVideoHandoff {
  final int postId;
  VideoPlayerController? controller;
  int urlIndex;
  bool userPaused;
  bool isMuted;
  double playbackSpeed;

  FullscreenVideoHandoff({
    required this.postId,
    this.controller,
    this.urlIndex = 0,
    this.userPaused = false,
    this.isMuted = false,
    this.playbackSpeed = 1.0,
  });
}

/// Result returned when exiting [FullscreenMediaPage] so [PostDetailPage] can
/// sync its active post index if the user swiped in fullscreen.
class FullscreenMediaResult {
  final int finalIndex;

  const FullscreenMediaResult({required this.finalIndex});
}

class _VideoTopBarState {
  final VoidCallback? onNextSource;
  final VoidCallback onReload;
  final String sourceLabel;

  const _VideoTopBarState({
    required this.onReload,
    this.onNextSource,
    this.sourceLabel = '',
  });
}

/// Pure-black immersive fullscreen viewer supporting pinch/double-tap image
/// zoom, cross-post swiping, swipe-down dismissal, and full video controls.
class FullscreenMediaPage extends StatefulWidget {
  final List<E621Post> posts;
  final int initialIndex;
  final FullscreenVideoHandoff? videoHandoff;
  final Future<List<E621Post>> Function()? onLoadMore;
  final Matrix4? initialImageMatrix;
  final bool instantTransition;

  const FullscreenMediaPage({
    super.key,
    required this.posts,
    required this.initialIndex,
    this.videoHandoff,
    this.onLoadMore,
    this.initialImageMatrix,
    this.instantTransition = false,
  });

  static Route<FullscreenMediaResult> route({
    required List<E621Post> posts,
    required int initialIndex,
    FullscreenVideoHandoff? videoHandoff,
    Future<List<E621Post>> Function()? onLoadMore,
    Matrix4? initialImageMatrix,
    bool instantTransition = false,
  }) {
    return PageRouteBuilder<FullscreenMediaResult>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration:
          instantTransition ? Duration.zero : const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, secondaryAnimation) {
        return FullscreenMediaPage(
          posts: posts,
          initialIndex: initialIndex,
          videoHandoff: videoHandoff,
          onLoadMore: onLoadMore,
          initialImageMatrix: initialImageMatrix,
          instantTransition: instantTransition,
        );
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (instantTransition && animation.status == AnimationStatus.forward) {
          return child;
        }
        return FadeTransition(opacity: animation, child: child);
      },
    );
  }

  @override
  State<FullscreenMediaPage> createState() => _FullscreenMediaPageState();
}

class _FullscreenMediaPageState extends State<FullscreenMediaPage>
    with SingleTickerProviderStateMixin {
  late List<E621Post> _posts;
  late int _currentIndex;
  late PageController _pageController;
  late final AnimationController _springBackController;
  Animation<double>? _springBackAnimation;

  final ValueNotifier<int> _zoomResetSignal = ValueNotifier<int>(0);
  final Set<int> _activePointers = <int>{};
  Matrix4? _pendingInitialImageMatrix;

  bool _isLoadingMore = false;
  bool _hudVisible = true;
  double _currentZoomScale = 1.0;
  bool _isCurrentPageZoomed = false;
  double _dragOffsetY = 0.0;
  bool _isDraggingToDismiss = false;
  bool _isScrubbingVideo = false;
  bool? _manualLandscapeOverride;
  double? _activeVideoAspectRatio;
  _VideoTopBarState? _activeVideoTopBar;
  bool _isExiting = false;

  bool get _isMultiTouch => _activePointers.length >= 2;
  E621Post get currentPost => _posts[_currentIndex];

  @override
  void initState() {
    super.initState();
    _posts = List<E621Post>.from(widget.posts);
    _currentIndex = _posts.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, _posts.length - 1);
    _pendingInitialImageMatrix = widget.initialImageMatrix?.clone();
    if (_pendingInitialImageMatrix != null) {
      final initialScale = _pendingInitialImageMatrix!.getMaxScaleOnAxis();
      if (initialScale > 1.02) {
        _currentZoomScale = initialScale;
        _isCurrentPageZoomed = true;
      }
    }
    _pageController = PageController(initialPage: _currentIndex);
    _springBackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(() {
        if (_springBackAnimation != null && mounted) {
          setState(() {
            _dragOffsetY = _springBackAnimation!.value;
          });
        }
      });

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _posts.isNotEmpty) {
        _precacheNeighbors(_currentIndex);
      }
    });
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _springBackController.dispose();
    _pageController.dispose();
    _zoomResetSignal.dispose();
    super.dispose();
  }

  void _restoreChrome() {
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _exitFullscreen() {
    if (_isExiting || !mounted) return;
    _isExiting = true;
    _restoreChrome();
    Navigator.of(context).pop(FullscreenMediaResult(finalIndex: _currentIndex));
  }

  void _precacheNeighbors(int index) {
    if (!mounted) return;
    void ignoreError(Object _, StackTrace? _) {}
    for (final offset in const [1, -1, 2]) {
      final i = index + offset;
      if (i < 0 || i >= _posts.length) continue;
      final previewUrl = _posts[i].previewUrl;
      if (previewUrl != null && previewUrl.isNotEmpty) {
        precacheImage(
          CachedNetworkImageProvider(previewUrl),
          context,
          onError: ignoreError,
        );
      }
    }
  }

  void _applyOrientation({double? videoAspectRatio}) {
    if (!mounted || _posts.isEmpty) return;
    if (!currentPost.isVideo) {
      SystemChrome.setPreferredOrientations(const []);
      return;
    }

    if (_manualLandscapeOverride != null) {
      if (_manualLandscapeOverride!) {
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      }
      return;
    }

    final aspect = videoAspectRatio ?? _activeVideoAspectRatio;
    if (aspect != null && aspect > 1.05) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(const []);
    }
  }

  void _toggleManualRotation() {
    final currentIsLandscape = _manualLandscapeOverride ??
        (_activeVideoAspectRatio != null && _activeVideoAspectRatio! > 1.05) ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    setState(() {
      _manualLandscapeOverride = !currentIsLandscape;
    });
    _applyOrientation();
  }

  void _onPageChanged(int index) {
    if (index < 0 || index >= _posts.length) return;
    setState(() {
      _currentIndex = index;
      _pendingInitialImageMatrix = null;
      _currentZoomScale = 1.0;
      _isCurrentPageZoomed = false;
      _manualLandscapeOverride = null;
      _activeVideoAspectRatio = null;
      _activeVideoTopBar = null;
      _isScrubbingVideo = false;
    });
    _applyOrientation();
    _precacheNeighbors(index);

    if (widget.onLoadMore != null &&
        index >= _posts.length - 3 &&
        !_isLoadingMore) {
      _triggerLoadMore();
    }
  }

  Future<void> _triggerLoadMore() async {
    if (_isLoadingMore || widget.onLoadMore == null) return;
    setState(() => _isLoadingMore = true);
    try {
      final updated = await widget.onLoadMore!();
      if (mounted && updated.isNotEmpty) {
        setState(() {
          _posts = List<E621Post>.from(updated);
        });
        _precacheNeighbors(_currentIndex);
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (_isCurrentPageZoomed || _isScrubbingVideo) return;
    _springBackController.stop();
    setState(() {
      _isDraggingToDismiss = true;
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_isCurrentPageZoomed || _isScrubbingVideo) return;
    if (!_isDraggingToDismiss) {
      setState(() => _isDraggingToDismiss = true);
    }
    setState(() {
      _dragOffsetY += details.delta.dy;
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_isDraggingToDismiss) return;
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_dragOffsetY.abs() > 110 || velocity.abs() > 700) {
      setState(() => _isDraggingToDismiss = false);
      _exitFullscreen();
      return;
    }

    setState(() => _isDraggingToDismiss = false);
    _springBackAnimation = Tween<double>(
      begin: _dragOffsetY,
      end: 0.0,
    ).animate(
      CurvedAnimation(
        parent: _springBackController,
        curve: Curves.easeOutCubic,
      ),
    );
    _springBackController.forward(from: 0.0);
  }

  void _downloadCurrentPost() {
    if (_posts.isEmpty) return;
    Map<String, String> headers = const {
      'User-Agent': 'SkerE621/1.0 (by anonymous on e621)',
    };
    try {
      headers = Provider.of<AuthProvider>(context, listen: false).mediaHeaders;
    } catch (_) {}
    DownloadService.downloadWithFeedback(
      context,
      currentPost,
      authHeaders: headers,
    );
  }

  Widget _buildTopHud() {
    final post = currentPost;
    final videoTopBar = post.isVideo ? _activeVideoTopBar : null;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !_hudVisible,
        child: AnimatedOpacity(
          opacity: _hudVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 180),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.78),
                  Colors.black.withValues(alpha: 0.35),
                  Colors.transparent,
                ],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Material(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        tooltip: 'Exit Fullscreen',
                        onPressed: _exitFullscreen,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'File #${post.id}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (_posts.length > 1)
                            Text(
                              '${_currentIndex + 1} of ${_posts.length}',
                              style: TextStyle(
                                color: Colors.grey[300],
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!post.isVideo && _currentZoomScale > 1.02) ...[
                      Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: Colors.blueAccent.withValues(alpha: 0.6),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            _zoomResetSignal.value++;
                          },
                          child: Tooltip(
                            message: 'Reset Zoom',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${_currentZoomScale.toStringAsFixed(1)}x',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.close,
                                    color: Colors.white70,
                                    size: 14,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (videoTopBar != null && videoTopBar.onNextSource != null) ...[
                      Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const StadiumBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: videoTopBar.onNextSource,
                          child: Tooltip(
                            message: 'Switch Video Source',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.swap_horiz,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    videoTopBar.sourceLabel,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (videoTopBar != null) ...[
                      Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          padding: EdgeInsets.zero,
                          icon: const Icon(
                            Icons.replay,
                            color: Colors.white,
                            size: 19,
                          ),
                          tooltip: 'Reload Video',
                          onPressed: videoTopBar.onReload,
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
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.download_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                        tooltip: 'Download Art',
                        onPressed: _downloadCurrentPost,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_posts.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: _exitFullscreen,
          ),
        ),
      );
    }

    final double backdropAlpha =
        (1.0 - (_dragOffsetY.abs() / 320.0)).clamp(0.0, 1.0);
    final double dragScale =
        (1.0 - (_dragOffsetY.abs() / 1200.0)).clamp(0.84, 1.0);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _exitFullscreen();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            final wasMulti = _isMultiTouch;
            _activePointers.add(event.pointer);
            if (!wasMulti && _isMultiTouch) {
              if (_pageController.hasClients &&
                  ((_pageController.page ?? _currentIndex) - _currentIndex)
                          .abs() >
                      0.001) {
                _pageController.jumpToPage(_currentIndex);
              }
              setState(() {
                if (_isDraggingToDismiss) {
                  _isDraggingToDismiss = false;
                  _dragOffsetY = 0.0;
                }
              });
            }
          },
          onPointerUp: (event) {
            final wasMulti = _isMultiTouch;
            _activePointers.remove(event.pointer);
            if (wasMulti != _isMultiTouch && mounted) {
              setState(() {});
            }
          },
          onPointerCancel: (event) {
            final wasMulti = _isMultiTouch;
            _activePointers.remove(event.pointer);
            if (wasMulti != _isMultiTouch && mounted) {
              setState(() {});
            }
          },
          child: Container(
            color: Colors.black.withValues(alpha: backdropAlpha),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Transform.translate(
                  offset: Offset(0, _dragOffsetY),
                  child: Transform.scale(
                    scale: dragScale,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragStart: (_isCurrentPageZoomed ||
                              _isScrubbingVideo ||
                              _isMultiTouch)
                          ? null
                          : _onVerticalDragStart,
                      onVerticalDragUpdate: (_isCurrentPageZoomed ||
                              _isScrubbingVideo ||
                              _isMultiTouch)
                          ? null
                          : _onVerticalDragUpdate,
                      onVerticalDragEnd: (_isCurrentPageZoomed ||
                              _isScrubbingVideo ||
                              _isMultiTouch)
                          ? null
                          : _onVerticalDragEnd,
                      child: PageView.builder(
                        controller: _pageController,
                        allowImplicitScrolling: true,
                        itemCount: _posts.length + (_isLoadingMore ? 1 : 0),
                        onPageChanged: _onPageChanged,
                        physics: (_isCurrentPageZoomed || _isMultiTouch)
                            ? const NeverScrollableScrollPhysics()
                            : const BouncingScrollPhysics(),
                        itemBuilder: (context, index) {
                          if (index == _posts.length) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final post = _posts[index];
                          final isActive = index == _currentIndex;
                          if (post.isVideo) {
                            return _FullscreenVideoSlide(
                              key: ValueKey('fs-video-${post.id}-$index'),
                              post: post,
                              isActive: isActive,
                              handoff: widget.videoHandoff != null &&
                                      widget.videoHandoff!.postId == post.id
                                  ? widget.videoHandoff
                                  : null,
                              hudVisible: _hudVisible,
                              onSetHudVisible: (visible) {
                                if (mounted && _hudVisible != visible) {
                                  setState(() => _hudVisible = visible);
                                }
                              },
                              onToggleHud: () {
                                if (mounted) {
                                  setState(() => _hudVisible = !_hudVisible);
                                }
                              },
                              onScrubbingChanged: (scrubbing) {
                                if (mounted && _isScrubbingVideo != scrubbing) {
                                  setState(() => _isScrubbingVideo = scrubbing);
                                }
                              },
                              onVideoAspectRatio: (aspect) {
                                if (!isActive || !mounted) return;
                                if (_activeVideoAspectRatio != aspect) {
                                  _activeVideoAspectRatio = aspect;
                                  _applyOrientation(videoAspectRatio: aspect);
                                }
                              },
                              onTopBarChanged: (state) {
                                if (!isActive || !mounted) return;
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (mounted && isActive) {
                                    setState(() => _activeVideoTopBar = state);
                                  }
                                });
                              },
                              onToggleRotation: _toggleManualRotation,
                              onExitFullscreen: _exitFullscreen,
                            );
                          }

                          return _FullscreenImageSlide(
                            key: ValueKey('fs-image-${post.id}-$index'),
                            post: post,
                            isActive: isActive,
                            initialMatrix: index == widget.initialIndex
                                ? _pendingInitialImageMatrix
                                : null,
                            resetSignal: _zoomResetSignal,
                            onTap: () {
                              if (mounted) {
                                setState(() => _hudVisible = !_hudVisible);
                              }
                            },
                            onZoomChanged: (scale) {
                              if (!isActive || !mounted) return;
                              final zoomed = scale > 1.02;
                              if ((_currentZoomScale - scale).abs() > 0.01 ||
                                  _isCurrentPageZoomed != zoomed) {
                                setState(() {
                                  _currentZoomScale = scale;
                                  _isCurrentPageZoomed = zoomed;
                                });
                              }
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ),
                if (!_isDraggingToDismiss) _buildTopHud(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenImageSlide extends StatefulWidget {
  final E621Post post;
  final bool isActive;
  final Matrix4? initialMatrix;
  final ValueNotifier<int> resetSignal;
  final VoidCallback onTap;
  final ValueChanged<double> onZoomChanged;

  const _FullscreenImageSlide({
    super.key,
    required this.post,
    required this.isActive,
    this.initialMatrix,
    required this.resetSignal,
    required this.onTap,
    required this.onZoomChanged,
  });

  @override
  State<_FullscreenImageSlide> createState() => _FullscreenImageSlideState();
}

class _FullscreenImageSlideState extends State<_FullscreenImageSlide> {
  bool _fullImageLoaded = false;

  Widget _buildSample({Widget? fallback}) {
    final sampleUrl = widget.post.previewUrl;
    final spinner = fallback ?? const Center(child: CircularProgressIndicator());
    if (sampleUrl == null || sampleUrl.isEmpty) return spinner;
    return CachedNetworkImage(
      imageUrl: sampleUrl,
      fit: BoxFit.contain,
      fadeInDuration: Duration.zero,
      placeholder: (context, url) => spinner,
      errorWidget: (context, url, error) =>
          fallback ?? const Center(child: Icon(Icons.broken_image, color: Colors.white54)),
    );
  }

  Widget _buildImageContent() {
    final previewUrl = widget.post.previewUrl;
    final fullUrl = widget.post.fileUrl;

    if ((previewUrl == null || previewUrl.isEmpty) &&
        (fullUrl == null || fullUrl.isEmpty)) {
      return const Center(
        child: Icon(Icons.image_not_supported, color: Colors.white54, size: 42),
      );
    }

    if (fullUrl == null || fullUrl.isEmpty || fullUrl == previewUrl) {
      return _buildSample();
    }

    final loadFullRes = _fullImageLoaded || widget.isActive;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildSample(),
        if (loadFullRes)
          CachedNetworkImage(
            imageUrl: fullUrl,
            fit: BoxFit.contain,
            fadeInDuration: const Duration(milliseconds: 120),
            fadeOutDuration: Duration.zero,
            imageBuilder: (context, imageProvider) {
              _fullImageLoaded = true;
              return Image(image: imageProvider, fit: BoxFit.contain);
            },
            placeholder: (context, url) => const Align(
              alignment: Alignment.bottomRight,
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(right: 16, bottom: 16),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
            errorWidget: (context, url, error) => const SizedBox.shrink(),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ZoomableImageView(
      initialMatrix: widget.initialMatrix,
      isActive: widget.isActive,
      resetSignal: widget.resetSignal,
      onTap: widget.onTap,
      onZoomChanged: widget.onZoomChanged,
      child: _buildImageContent(),
    );
  }
}

class _FullscreenVideoSlide extends StatefulWidget {
  final E621Post post;
  final bool isActive;
  final FullscreenVideoHandoff? handoff;
  final bool hudVisible;
  final ValueChanged<bool> onSetHudVisible;
  final VoidCallback onToggleHud;
  final ValueChanged<bool> onScrubbingChanged;
  final ValueChanged<double> onVideoAspectRatio;
  final ValueChanged<_VideoTopBarState?> onTopBarChanged;
  final VoidCallback onToggleRotation;
  final VoidCallback onExitFullscreen;

  const _FullscreenVideoSlide({
    super.key,
    required this.post,
    required this.isActive,
    required this.handoff,
    required this.hudVisible,
    required this.onSetHudVisible,
    required this.onToggleHud,
    required this.onScrubbingChanged,
    required this.onVideoAspectRatio,
    required this.onTopBarChanged,
    required this.onToggleRotation,
    required this.onExitFullscreen,
  });

  @override
  State<_FullscreenVideoSlide> createState() => _FullscreenVideoSlideState();
}

class _FullscreenVideoSlideState extends State<_FullscreenVideoSlide>
    with WidgetsBindingObserver {
  static const List<double> _speedSteps = [0.5, 1.0, 1.5, 2.0];

  VideoPlayerController? _videoController;
  VoidCallback? _activeListener;
  Timer? _settleActivationTimer;
  Timer? _hudAutoHideTimer;
  Timer? _seekBadgeTimer;

  int _videoInitToken = 0;
  int _currentVideoUrlIndex = 0;
  bool _videoError = false;
  bool _userPaused = false;
  bool _isMuted = false;
  double _playbackSpeed = 1.0;
  bool _isRecoveringLoop = false;
  bool _borrowedFromHandoff = false;
  bool _isScrubbing = false;
  double? _scrubValueMs;
  Size _lastKnownVideoSize = Size.zero;
  int? _seekFeedbackSeconds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final handoff = widget.handoff;
    if (handoff != null &&
        handoff.postId == widget.post.id &&
        handoff.controller != null) {
      _adoptHandoffController(handoff);
    } else if (widget.isActive) {
      _initVideo();
    }

    if (widget.isActive) {
      _notifyTopBar();
      _scheduleHudAutoHide();
    }
  }

  void _adoptHandoffController(FullscreenVideoHandoff handoff) {
    final controller = handoff.controller!;
    _borrowedFromHandoff = true;
    _videoController = controller;
    _currentVideoUrlIndex = handoff.urlIndex;
    _userPaused = handoff.userPaused;
    _isMuted = handoff.isMuted;
    _playbackSpeed = handoff.playbackSpeed;
    _lastKnownVideoSize = controller.value.size;

    final token = ++_videoInitToken;
    _attachListener(controller, token);

    if (controller.value.isInitialized) {
      final aspect = controller.value.aspectRatio;
      if (aspect > 0 && aspect.isFinite) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.isActive) {
            widget.onVideoAspectRatio(aspect);
          }
        });
      }
    }
  }

  void _attachListener(VideoPlayerController controller, int token) {
    _detachListener(controller);
    void listener() => _onVideoControllerUpdate(controller, token);
    _activeListener = listener;
    controller.addListener(listener);
  }

  void _detachListener(VideoPlayerController? controller) {
    if (controller != null && _activeListener != null) {
      controller.removeListener(_activeListener!);
    }
    _activeListener = null;
  }

  void _notifyTopBar() {
    if (!widget.isActive) return;
    final urls = widget.post.playableVideoUrls;
    widget.onTopBarChanged(
      _VideoTopBarState(
        onReload: _retryVideo,
        onNextSource: urls.length > 1 ? _nextVideoSource : null,
        sourceLabel: '${_currentVideoUrlIndex + 1}/${urls.length}',
      ),
    );
  }

  @override
  void didUpdateWidget(_FullscreenVideoSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _videoError = false;
      _notifyTopBar();
      _scheduleHudAutoHide();
      _settleActivationTimer?.cancel();
      _settleActivationTimer = Timer(const Duration(milliseconds: 100), () {
        if (!mounted || !widget.isActive) return;
        if (_videoController == null && !_videoError) {
          _initVideo();
        } else if (_videoController != null &&
            _videoController!.value.isInitialized &&
            !_userPaused) {
          _videoController!.play();
        }
      });
    } else if (!widget.isActive && oldWidget.isActive) {
      _settleActivationTimer?.cancel();
      _settleActivationTimer = null;
      _hudAutoHideTimer?.cancel();
      _disposeVideo(notify: true);
    }

    if (widget.hudVisible && !oldWidget.hudVisible) {
      _scheduleHudAutoHide();
    } else if (!widget.hudVisible && oldWidget.hudVisible) {
      _hudAutoHideTimer?.cancel();
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
      if (mounted && widget.isActive) {
        if (controller.value.hasError) {
          _retryVideo();
        } else if (!_userPaused) {
          controller.play();
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settleActivationTimer?.cancel();
    _hudAutoHideTimer?.cancel();
    _seekBadgeTimer?.cancel();

    final controller = _videoController;
    if (_borrowedFromHandoff && widget.isActive && widget.handoff != null) {
      _detachListener(controller);
      widget.handoff!.controller = controller;
      widget.handoff!.urlIndex = _currentVideoUrlIndex;
      widget.handoff!.userPaused = _userPaused;
      widget.handoff!.isMuted = _isMuted;
      widget.handoff!.playbackSpeed = _playbackSpeed;
      _videoController = null;
    } else {
      _disposeVideo(notify: false);
    }
    super.dispose();
  }

  void _disposeVideo({bool notify = false}) {
    _videoInitToken++;
    _isRecoveringLoop = false;
    _lastKnownVideoSize = Size.zero;
    final old = _videoController;
    _videoController = null;
    _detachListener(old);
    if (_borrowedFromHandoff && widget.handoff != null) {
      if (widget.handoff!.controller == old) {
        widget.handoff!.controller = null;
      }
      _borrowedFromHandoff = false;
    }
    if (old != null) {
      old.dispose();
      if (notify && mounted) {
        setState(() {});
      }
    }
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
    _detachListener(old);
    if (old != null) {
      old.dispose();
    }

    final String targetUrl = urls[_currentVideoUrlIndex];
    Map<String, String> headers = const {
      'User-Agent': 'SkerE621/1.0 (by anonymous on e621)',
    };
    try {
      headers = Provider.of<AuthProvider>(context, listen: false).mediaHeaders;
    } catch (_) {}

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(targetUrl),
      httpHeaders: headers,
      viewType: preferredVideoViewType,
    );
    _videoController = controller;
    if (_borrowedFromHandoff && widget.handoff != null) {
      widget.handoff!.controller = controller;
    }
    _attachListener(controller, token);

    try {
      await controller.initialize();
      if (!mounted || token != _videoInitToken || !widget.isActive) {
        if (_videoController == controller) {
          _videoController = null;
          _detachListener(controller);
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
      if (_playbackSpeed != 1.0) {
        await controller.setPlaybackSpeed(_playbackSpeed);
      }

      if (!mounted || token != _videoInitToken || !widget.isActive) {
        if (_videoController == controller) {
          _videoController = null;
          _detachListener(controller);
        }
        controller.dispose();
        return;
      }

      _lastKnownVideoSize = controller.value.size;
      final aspect = controller.value.aspectRatio;
      if (aspect > 0 && aspect.isFinite) {
        widget.onVideoAspectRatio(aspect);
      }
      setState(() {
        _videoError = false;
      });
      _notifyTopBar();

      if (!_userPaused) {
        await controller.play();
      }
      _scheduleHudAutoHide();
    } catch (_) {
      if (mounted && token == _videoInitToken) {
        _handleVideoFailure(token);
      } else {
        if (_videoController == controller) {
          _videoController = null;
          _detachListener(controller);
        }
        controller.dispose();
      }
    }
  }

  void _onVideoControllerUpdate(VideoPlayerController controller, int token) {
    if (!mounted || token != _videoInitToken || _videoController != controller) {
      return;
    }
    final val = controller.value;

    if (val.hasError) {
      _handleVideoFailure(token);
      return;
    }
    if (!val.isInitialized) return;

    if (val.size != _lastKnownVideoSize && val.size != Size.zero) {
      _lastKnownVideoSize = val.size;
      final aspect = val.aspectRatio;
      if (aspect > 0 && aspect.isFinite && widget.isActive) {
        widget.onVideoAspectRatio(aspect);
      }
      setState(() {});
    }

    if (!_userPaused &&
        !_isRecoveringLoop &&
        !_isScrubbing &&
        (val.isCompleted ||
            (!val.isPlaying &&
                !val.isBuffering &&
                val.duration > Duration.zero &&
                val.position >= val.duration - const Duration(milliseconds: 200)))) {
      _isRecoveringLoop = true;
      Future<void>.delayed(const Duration(milliseconds: 16)).then((_) {
        if (!mounted ||
            token != _videoInitToken ||
            _videoController != controller) {
          return null;
        }
        return controller.seekTo(Duration.zero);
      }).then((_) {
        if (mounted &&
            token == _videoInitToken &&
            _videoController == controller &&
            !_userPaused) {
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
      _notifyTopBar();
      _initVideo();
    } else {
      setState(() {
        _videoError = true;
      });
    }
  }

  void _retryVideo() {
    if (!mounted) return;
    setState(() {
      _videoError = false;
      _userPaused = false;
      _currentVideoUrlIndex = 0;
    });
    _notifyTopBar();
    _initVideo();
  }

  void _nextVideoSource() {
    if (!mounted) return;
    final count = widget.post.playableVideoUrls.length;
    if (count < 2) return;
    setState(() {
      _videoError = false;
      _userPaused = false;
      _currentVideoUrlIndex = (_currentVideoUrlIndex + 1) % count;
    });
    _notifyTopBar();
    _initVideo();
  }

  void _scheduleHudAutoHide() {
    _hudAutoHideTimer?.cancel();
    if (!widget.isActive || !widget.hudVisible || _isScrubbing) return;
    final controller = _videoController;
    final isPlaying = controller != null &&
        controller.value.isInitialized &&
        controller.value.isPlaying;
    if (!isPlaying || _userPaused) return;

    _hudAutoHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !widget.isActive || _isScrubbing || _userPaused) return;
      widget.onSetHudVisible(false);
    });
  }

  void _togglePlayPause() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      _userPaused = true;
      controller.pause();
      _hudAutoHideTimer?.cancel();
      widget.onSetHudVisible(true);
    } else {
      _userPaused = false;
      controller.play();
      _scheduleHudAutoHide();
    }
    setState(() {});
  }

  void _toggleMute() {
    final controller = _videoController;
    _isMuted = !_isMuted;
    if (controller != null && controller.value.isInitialized) {
      controller.setVolume(_isMuted ? 0.0 : 1.0);
    }
    _scheduleHudAutoHide();
    setState(() {});
  }

  void _cyclePlaybackSpeed() {
    final idx = _speedSteps.indexOf(_playbackSpeed);
    final nextIndex = idx == -1 ? 2 : (idx + 1) % _speedSteps.length;
    final nextSpeed = _speedSteps[nextIndex];
    setState(() {
      _playbackSpeed = nextSpeed;
    });
    final controller = _videoController;
    if (controller != null && controller.value.isInitialized) {
      controller.setPlaybackSpeed(nextSpeed);
    }
    _scheduleHudAutoHide();
  }

  void _seekRelative(int deltaSeconds) {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    final duration = controller.value.duration;
    final current = controller.value.position;
    final targetMs = (current.inMilliseconds + deltaSeconds * 1000)
        .clamp(0, duration.inMilliseconds);
    controller.seekTo(Duration(milliseconds: targetMs));

    _seekBadgeTimer?.cancel();
    setState(() {
      _seekFeedbackSeconds = deltaSeconds;
    });
    _seekBadgeTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() => _seekFeedbackSeconds = null);
      }
    });
    _scheduleHudAutoHide();
  }

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds.clamp(0, 359999);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }

  String _formatSpeedLabel(double speed) {
    if (speed == speed.roundToDouble()) {
      return '${speed.toInt()}x';
    }
    return '${speed}x';
  }

  Widget _buildSample({Widget? fallback}) {
    final sampleUrl = widget.post.previewUrl;
    final spinner = fallback ?? const SizedBox.shrink();
    if (sampleUrl == null || sampleUrl.isEmpty) return spinner;
    return CachedNetworkImage(
      imageUrl: sampleUrl,
      fit: BoxFit.contain,
      fadeInDuration: Duration.zero,
      placeholder: (context, url) => spinner,
      errorWidget: (context, url, error) => spinner,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_videoError) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildSample(),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onToggleHud,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 32),
                    const SizedBox(height: 8),
                    const Text(
                      'Video failed to load',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
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
          ),
        ],
      );
    }

    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggleHud,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildSample(),
            const Center(child: CircularProgressIndicator()),
          ],
        ),
      );
    }

    final rawAspect = controller.value.aspectRatio;
    final safeAspect =
        (rawAspect > 0 && rawAspect.isFinite) ? rawAspect : (16.0 / 9.0);

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final isPlaying = value.isPlaying;
        final isBuffering = value.isBuffering;
        final isMuted = value.volume == 0.0 || _isMuted;
        final durationMs = value.duration.inMilliseconds.toDouble();
        final positionMs = (_scrubValueMs ?? value.position.inMilliseconds.toDouble())
            .clamp(0.0, durationMs > 0 ? durationMs : 1.0);
        final displayPos = Duration(milliseconds: positionMs.round());

        return Stack(
          fit: StackFit.expand,
          children: [
            _buildSample(),
            Center(
              child: AspectRatio(
                aspectRatio: safeAspect,
                child: VideoPlayer(
                  controller,
                  key: ObjectKey(controller),
                ),
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    widget.onToggleHud();
                    if (!widget.hudVisible) {
                      _scheduleHudAutoHide();
                    }
                  },
                  onDoubleTapDown: (details) {
                    final dx = details.localPosition.dx;
                    final half = constraints.maxWidth / 2;
                    if (dx < half) {
                      _seekRelative(-5);
                    } else {
                      _seekRelative(5);
                    }
                  },
                  onDoubleTap: () {},
                  child: const SizedBox.expand(),
                );
              },
            ),
            if (isBuffering)
              const Center(
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            if (_seekFeedbackSeconds != null)
              Align(
                alignment: _seekFeedbackSeconds! < 0
                    ? const Alignment(-0.5, 0.0)
                    : const Alignment(0.5, 0.0),
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _seekFeedbackSeconds! < 0
                              ? Icons.replay_5
                              : Icons.forward_5,
                          color: Colors.white,
                          size: 22,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _seekFeedbackSeconds! < 0 ? '-5s' : '+5s',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            IgnorePointer(
              ignoring: !widget.hudVisible,
              child: AnimatedOpacity(
                opacity: widget.hudVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: IconButton(
                          iconSize: 28,
                          padding: const EdgeInsets.all(10),
                          icon: const Icon(Icons.replay_5, color: Colors.white),
                          tooltip: 'Rewind 5s',
                          onPressed: () => _seekRelative(-5),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Material(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: IconButton(
                          iconSize: 40,
                          padding: const EdgeInsets.all(14),
                          icon: Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                          ),
                          tooltip: isPlaying ? 'Pause' : 'Play',
                          onPressed: _togglePlayPause,
                        ),
                      ),
                      const SizedBox(width: 24),
                      Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: IconButton(
                          iconSize: 28,
                          padding: const EdgeInsets.all(10),
                          icon: const Icon(Icons.forward_5, color: Colors.white),
                          tooltip: 'Forward 5s',
                          onPressed: () => _seekRelative(5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !widget.hudVisible,
                child: AnimatedOpacity(
                  opacity: widget.hudVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.82),
                          Colors.black.withValues(alpha: 0.4),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(
                                  _formatDuration(displayPos),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontFeatures: [FontFeature.tabularFigures()],
                                  ),
                                ),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 6,
                                      ),
                                      overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 14,
                                      ),
                                      activeTrackColor: Colors.blueAccent,
                                      inactiveTrackColor: Colors.white24,
                                      thumbColor: Colors.blueAccent,
                                    ),
                                    child: Slider(
                                      value: durationMs > 0
                                          ? positionMs.clamp(0.0, durationMs)
                                          : 0.0,
                                      min: 0.0,
                                      max: durationMs > 0 ? durationMs : 1.0,
                                      onChangeStart: (v) {
                                        _hudAutoHideTimer?.cancel();
                                        _isScrubbing = true;
                                        _scrubValueMs = v;
                                        widget.onScrubbingChanged(true);
                                      },
                                      onChanged: durationMs > 0
                                          ? (v) {
                                              setState(() => _scrubValueMs = v);
                                            }
                                          : null,
                                      onChangeEnd: (v) async {
                                        _isScrubbing = false;
                                        widget.onScrubbingChanged(false);
                                        if (durationMs > 0) {
                                          await controller.seekTo(
                                            Duration(milliseconds: v.round()),
                                          );
                                        }
                                        if (mounted) {
                                          setState(() => _scrubValueMs = null);
                                        }
                                        _scheduleHudAutoHide();
                                      },
                                    ),
                                  ),
                                ),
                                Text(
                                  _formatDuration(value.duration),
                                  style: TextStyle(
                                    color: Colors.grey[300],
                                    fontSize: 12,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                Material(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: const CircleBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                    padding: EdgeInsets.zero,
                                    icon: Icon(
                                      isMuted ? Icons.volume_off : Icons.volume_up,
                                      color: Colors.white,
                                      size: 19,
                                    ),
                                    tooltip: isMuted ? 'Unmute' : 'Mute',
                                    onPressed: _toggleMute,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Material(
                                  color: _playbackSpeed != 1.0
                                      ? Colors.blueAccent.withValues(alpha: 0.25)
                                      : Colors.black.withValues(alpha: 0.55),
                                  shape: StadiumBorder(
                                    side: BorderSide(
                                      color: _playbackSpeed != 1.0
                                          ? Colors.blueAccent
                                          : Colors.white24,
                                    ),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: _cyclePlaybackSpeed,
                                    child: Tooltip(
                                      message: 'Playback Speed',
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        child: Text(
                                          _formatSpeedLabel(_playbackSpeed),
                                          style: TextStyle(
                                            color: _playbackSpeed != 1.0
                                                ? Colors.blueAccent[100]
                                                : Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Material(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: const CircleBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                    padding: EdgeInsets.zero,
                                    icon: const Icon(
                                      Icons.screen_rotation,
                                      color: Colors.white,
                                      size: 19,
                                    ),
                                    tooltip: 'Rotate Screen',
                                    onPressed: () {
                                      widget.onToggleRotation();
                                      _scheduleHudAutoHide();
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Material(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: const CircleBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                    padding: EdgeInsets.zero,
                                    icon: const Icon(
                                      Icons.fullscreen_exit,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                    tooltip: 'Exit Fullscreen',
                                    onPressed: widget.onExitFullscreen,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
