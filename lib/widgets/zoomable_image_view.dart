import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A [ScaleGestureRecognizer] tailored for image galleries inside a [PageView].
///
/// - When 2+ pointers touch down, it immediately claims the gesture arena so
///   pinch-to-zoom never loses to horizontal [PageView] swiping or vertical
///   scroll/dismiss drags.
/// - When [allowSinglePointerPan] is `false` (image is at 1.0x) and a single
///   pointer moves beyond [kTouchSlop], it rejects itself immediately so
///   1-finger swipes pass straight through to the parent [PageView] or scroll
///   container.
class SmartScaleGestureRecognizer extends ScaleGestureRecognizer {
  bool allowSinglePointerPan;
  final Map<int, Offset> _downPositions = <int, Offset>{};

  SmartScaleGestureRecognizer({
    required this.allowSinglePointerPan,
    super.debugOwner,
  });

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _downPositions[event.pointer] = event.position;
    super.addAllowedPointer(event);
    if (_downPositions.length >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _downPositions.remove(event.pointer);
      super.handleEvent(event);
      return;
    }

    if (event is PointerMoveEvent &&
        !allowSinglePointerPan &&
        _downPositions.length < 2) {
      final downPos = _downPositions[event.pointer] ?? event.position;
      if ((event.position - downPos).distance > kTouchSlop) {
        _downPositions.remove(event.pointer);
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
        return;
      }
    }

    super.handleEvent(event);
  }

  @override
  void rejectGesture(int pointer) {
    _downPositions.remove(pointer);
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _downPositions.clear();
    super.didStopTrackingLastPointer(pointer);
  }
}

/// Builds a zoom/pan [Matrix4] clamped to [viewportSize].
///
/// When [scale] >= 1.0, translations are clamped so the content edges never
/// detach from the viewport. When [scale] < 1.0 (temporary pinch rubber-band),
/// the content stays gently centered with damped translation.
Matrix4 buildClampedZoomMatrix({
  required double scale,
  required double tx,
  required double ty,
  required Size viewportSize,
}) {
  final double clampedTx;
  final double clampedTy;

  if (scale >= 1.0) {
    final minTx = viewportSize.width * (1.0 - scale);
    final minTy = viewportSize.height * (1.0 - scale);
    clampedTx = tx.clamp(minTx, 0.0);
    clampedTy = ty.clamp(minTy, 0.0);
  } else {
    final centerTx = viewportSize.width * (1.0 - scale) * 0.5;
    final centerTy = viewportSize.height * (1.0 - scale) * 0.5;
    clampedTx = centerTx + (tx - centerTx) * 0.25;
    clampedTy = centerTy + (ty - centerTy) * 0.25;
  }

  return Matrix4.diagonal3Values(scale, scale, 1.0)
    ..setTranslationRaw(clampedTx, clampedTy, 0.0);
}

/// Smooth pinch-to-zoom, pan-when-zoomed, and focal-point double-tap image
/// container designed to coexist cleanly with a parent [PageView].
class ZoomableImageView extends StatefulWidget {
  final Widget child;
  final Matrix4? initialMatrix;
  final bool isActive;
  final ValueNotifier<int>? resetSignal;
  final VoidCallback? onTap;
  final ValueChanged<double>? onZoomChanged;
  final double minScale;
  final double maxScale;
  final double rubberBandMinScale;

  const ZoomableImageView({
    super.key,
    required this.child,
    this.initialMatrix,
    this.isActive = true,
    this.resetSignal,
    this.onTap,
    this.onZoomChanged,
    this.minScale = 1.0,
    this.maxScale = 6.0,
    this.rubberBandMinScale = 0.85,
  });

  @override
  State<ZoomableImageView> createState() => _ZoomableImageViewState();
}

class _ZoomableImageViewState extends State<ZoomableImageView>
    with SingleTickerProviderStateMixin {
  late Matrix4 _matrix;
  late final AnimationController _animController;
  Animation<Matrix4>? _matrixAnimation;

  double _startScale = 1.0;
  double _startTx = 0.0;
  double _startTy = 0.0;
  Offset _startFocalPoint = Offset.zero;
  Offset? _doubleTapLocalPosition;
  bool _isZoomed = false;

  double get _currentScale => _matrix.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    _matrix = widget.initialMatrix?.clone() ?? Matrix4.identity();
    _isZoomed = _currentScale > 1.02;

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() {
        if (_matrixAnimation != null && mounted) {
          _applyMatrix(_matrixAnimation!.value);
        }
      });

    widget.resetSignal?.addListener(_handleExternalReset);
  }

  @override
  void didUpdateWidget(ZoomableImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetSignal != widget.resetSignal) {
      oldWidget.resetSignal?.removeListener(_handleExternalReset);
      widget.resetSignal?.addListener(_handleExternalReset);
    }
    if (!widget.isActive && oldWidget.isActive && _isZoomed) {
      _animController.stop();
      _applyMatrix(Matrix4.identity());
    }
  }

  @override
  void dispose() {
    widget.resetSignal?.removeListener(_handleExternalReset);
    _animController.dispose();
    super.dispose();
  }

  void _handleExternalReset() {
    if (!widget.isActive) return;
    _animateToMatrix(Matrix4.identity());
  }

  void _applyMatrix(Matrix4 next) {
    final scale = next.getMaxScaleOnAxis();
    final zoomed = scale > 1.02;
    setState(() {
      _matrix = next;
      _isZoomed = zoomed;
    });
    if (widget.isActive) {
      widget.onZoomChanged?.call(scale);
    }
  }

  void _animateToMatrix(Matrix4 target) {
    _animController.stop();
    _matrixAnimation = Matrix4Tween(
      begin: _matrix.clone(),
      end: target,
    ).animate(
      CurvedAnimation(
        parent: _animController,
        curve: Curves.easeOutCubic,
      ),
    );
    _animController.forward(from: 0.0);
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _animController.stop();
    _startScale = _currentScale;
    _startTx = _matrix.storage[12];
    _startTy = _matrix.storage[13];
    _startFocalPoint = details.localFocalPoint;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details, Size viewportSize) {
    final newScale = (_startScale * details.scale)
        .clamp(widget.rubberBandMinScale, widget.maxScale);
    final ratio = newScale / _startScale;
    final rawTx =
        details.localFocalPoint.dx - (_startFocalPoint.dx - _startTx) * ratio;
    final rawTy =
        details.localFocalPoint.dy - (_startFocalPoint.dy - _startTy) * ratio;

    final next = buildClampedZoomMatrix(
      scale: newScale,
      tx: rawTx,
      ty: rawTy,
      viewportSize: viewportSize,
    );
    _applyMatrix(next);
  }

  void _handleScaleEnd() {
    if (_currentScale <= 1.02 && _currentScale != 1.0) {
      _animateToMatrix(Matrix4.identity());
    }
  }

  void _handleDoubleTap(Size viewportSize) {
    if (_currentScale > 1.05) {
      _animateToMatrix(Matrix4.identity());
      return;
    }

    const double targetScale = 2.5;
    final pos = _doubleTapLocalPosition ??
        Offset(viewportSize.width / 2, viewportSize.height / 2);
    final rawTx = pos.dx * (1.0 - targetScale);
    final rawTy = pos.dy * (1.0 - targetScale);

    _animateToMatrix(
      buildClampedZoomMatrix(
        scale: targetScale,
        tx: rawTx,
        ty: rawTy,
        viewportSize: viewportSize,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTapDown: (details) {
            _doubleTapLocalPosition = details.localPosition;
          },
          onDoubleTap: () => _handleDoubleTap(viewportSize),
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory>{
              SmartScaleGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                      SmartScaleGestureRecognizer>(
                () => SmartScaleGestureRecognizer(
                  allowSinglePointerPan: _isZoomed,
                  debugOwner: this,
                ),
                (SmartScaleGestureRecognizer instance) {
                  instance.allowSinglePointerPan = _isZoomed;
                  instance.onStart = _handleScaleStart;
                  instance.onUpdate =
                      (details) => _handleScaleUpdate(details, viewportSize);
                  instance.onEnd = (_) => _handleScaleEnd();
                },
              ),
            },
            child: ClipRect(
              child: Transform(
                transform: _matrix,
                alignment: Alignment.topLeft,
                child: SizedBox.expand(child: widget.child),
              ),
            ),
          ),
        );
      },
    );
  }
}
