import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/tag_autocomplete_service.dart';

/// A search bar with live e621 tag & metatag autocomplete suggestions.
/// Completes the individual tag token at the current cursor position while
/// preserving other tags and modifiers (`-` or `~`) in the search bar.
class TagSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;
  final VoidCallback? onCleared;
  final String hintText;
  final BoxDecoration? decoration;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? hintStyle;
  final TagAutocompleteService? autocompleteService;
  final Duration debounceDuration;

  const TagSearchBar({
    super.key,
    required this.controller,
    required this.onSubmitted,
    this.onCleared,
    this.hintText = 'Search (ex: dragon order:score)',
    this.decoration,
    this.contentPadding,
    this.hintStyle,
    this.autocompleteService,
    this.debounceDuration = const Duration(milliseconds: 220),
  });

  @override
  State<TagSearchBar> createState() => _TagSearchBarState();
}

class _TagSearchBarState extends State<TagSearchBar> {
  static final TagAutocompleteService _defaultService = TagAutocompleteService();

  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _overlayController = OverlayPortalController();
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _targetKey = GlobalKey();
  final Object _tapRegionGroupId = Object();

  Timer? _debounceTimer;
  int _requestId = 0;
  bool _isLoading = false;
  List<TagSuggestion> _suggestions = const [];
  TagTokenContext? _activeToken;
  int _highlightedIndex = -1;
  double _targetWidth = 300;

  TagAutocompleteService get _service => widget.autocompleteService ?? _defaultService;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) {
      _hideOverlay();
    }
  }

  void _measureTargetWidth() {
    final renderObject = _targetKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      _targetWidth = renderObject.size.width;
    }
  }

  void _onTextChanged(String text) {
    _debounceTimer?.cancel();

    final cursorOffset = widget.controller.selection.isValid
        ? widget.controller.selection.baseOffset
        : text.length;
    final token = TagTokenContext.extract(text, cursorOffset);

    if (token == null || token.query.trim().isEmpty) {
      _requestId++;
      setState(() {
        _isLoading = false;
        _suggestions = const [];
        _activeToken = null;
        _highlightedIndex = -1;
      });
      _hideOverlay();
      return;
    }

    _activeToken = token;

    if (widget.debounceDuration == Duration.zero) {
      _fetchForToken(token);
    } else {
      _debounceTimer = Timer(widget.debounceDuration, () {
        if (mounted) {
          _fetchForToken(token);
        }
      });
    }
  }

  Future<void> _fetchForToken(TagTokenContext token) async {
    final currentRequest = ++_requestId;
    _measureTargetWidth();

    Map<String, String>? headers;
    try {
      headers = Provider.of<AuthProvider>(context, listen: false).authHeaders;
    } catch (_) {
      headers = null;
    }

    setState(() {
      _isLoading = true;
    });

    final results = await _service.fetchSuggestions(
      token.query,
      headers: headers,
      limit: 8,
    );

    if (!mounted || currentRequest != _requestId) return;

    setState(() {
      _isLoading = false;
      _suggestions = results;
      _highlightedIndex = -1;
    });

    if (_suggestions.isNotEmpty && _focusNode.hasFocus) {
      _showOverlay();
    } else {
      _hideOverlay();
    }
  }

  void _showOverlay() {
    _measureTargetWidth();
    if (!_overlayController.isShowing) {
      _overlayController.show();
    }
  }

  void _hideOverlay() {
    _debounceTimer?.cancel();
    if (_overlayController.isShowing) {
      _overlayController.hide();
    }
    if (mounted && (_suggestions.isNotEmpty || _isLoading)) {
      setState(() {
        _suggestions = const [];
        _isLoading = false;
        _highlightedIndex = -1;
      });
    }
  }

  void _selectSuggestion(TagSuggestion suggestion) {
    final text = widget.controller.text;
    final cursorOffset = widget.controller.selection.isValid
        ? widget.controller.selection.baseOffset
        : text.length;
    final token = TagTokenContext.extract(text, cursorOffset) ?? _activeToken;

    if (token != null) {
      final newValue = token.applySuggestion(suggestion.name);
      widget.controller.value = newValue;
    } else {
      final appended = '${suggestion.name} ';
      widget.controller.value = TextEditingValue(
        text: appended,
        selection: TextSelection.collapsed(offset: appended.length),
      );
    }

    _requestId++;
    _hideOverlay();
    _focusNode.requestFocus();
  }

  void _submitSearch(String value) {
    _requestId++;
    _hideOverlay();
    _focusNode.unfocus();
    widget.onSubmitted(value);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_overlayController.isShowing || _suggestions.isEmpty) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlightedIndex = (_highlightedIndex + 1) % _suggestions.length;
      });
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlightedIndex = (_highlightedIndex - 1 + _suggestions.length) % _suggestions.length;
      });
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.tab) {
      final index = _highlightedIndex >= 0 ? _highlightedIndex : 0;
      _selectSuggestion(_suggestions[index]);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_highlightedIndex >= 0 && _highlightedIndex < _suggestions.length) {
        _selectSuggestion(_suggestions[_highlightedIndex]);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      _hideOverlay();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Widget _buildSuggestionTitle(TagSuggestion suggestion, String activeQuery) {
    final normalizedQuery = activeQuery.trim().toLowerCase();
    final prefixMod = _activeToken?.prefixModifier ?? '';

    if (suggestion.antecedentName != null && suggestion.antecedentName!.isNotEmpty) {
      return RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: const TextStyle(fontSize: 13.5, color: Colors.white),
          children: [
            if (prefixMod.isNotEmpty)
              TextSpan(
                text: prefixMod,
                style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
              ),
            TextSpan(
              text: suggestion.antecedentName!,
              style: TextStyle(color: Colors.grey[400], fontStyle: FontStyle.italic),
            ),
            TextSpan(
              text: ' → ',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            TextSpan(
              text: suggestion.name,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    final name = suggestion.name;
    if (normalizedQuery.isNotEmpty && name.toLowerCase().startsWith(normalizedQuery)) {
      final matchLen = normalizedQuery.length.clamp(0, name.length);
      return RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: const TextStyle(fontSize: 13.5, color: Colors.white),
          children: [
            if (prefixMod.isNotEmpty)
              TextSpan(
                text: prefixMod,
                style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
              ),
            TextSpan(
              text: name.substring(0, matchLen),
              style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
            ),
            TextSpan(
              text: name.substring(matchLen),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    return Text(
      '$prefixMod$name',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13.5, color: Colors.white),
    );
  }

  Widget _buildOverlayContent(BuildContext context) {
    final activeQuery = _activeToken?.query ?? '';
    final width = _targetWidth < 260 ? 260.0 : _targetWidth;

    return CompositedTransformFollower(
      link: _layerLink,
      showWhenUnlinked: false,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, 6),
      child: Align(
        alignment: Alignment.topLeft,
        child: TapRegion(
          groupId: _tapRegionGroupId,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: width,
              constraints: const BoxConstraints(maxHeight: 290),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey[800]!, width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black87,
                    blurRadius: 12,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  itemCount: _suggestions.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    color: Colors.grey[850],
                  ),
                  itemBuilder: (context, index) {
                    final suggestion = _suggestions[index];
                    final isHighlighted = index == _highlightedIndex;
                    final catColor = suggestion.categoryColor;
                    final countText = suggestion.formattedPostCount;

                    return InkWell(
                      onTap: () => _selectSuggestion(suggestion),
                      child: Container(
                        color: isHighlighted
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: catColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildSuggestionTitle(suggestion, activeQuery),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: catColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: catColor.withValues(alpha: 0.4),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                suggestion.categoryLabel,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: catColor,
                                ),
                              ),
                            ),
                            if (countText.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Text(
                                countText,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.grey[400],
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
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
    return TapRegion(
      groupId: _tapRegionGroupId,
      onTapOutside: (_) => _hideOverlay(),
      child: OverlayPortal(
        controller: _overlayController,
        overlayChildBuilder: _buildOverlayContent,
        child: CompositedTransformTarget(
          link: _layerLink,
          child: Container(
            key: _targetKey,
            height: 45,
            decoration: widget.decoration ??
                BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(8),
                ),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) {
                final hasText = value.text.isNotEmpty;
                return Focus(
                  onKeyEvent: _handleKeyEvent,
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.search,
                    onChanged: _onTextChanged,
                    onSubmitted: _submitSearch,
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      hintStyle: widget.hintStyle,
                      border: InputBorder.none,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _isLoading
                          ? const Padding(
                              padding: EdgeInsets.all(13.0),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : (hasText
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  tooltip: 'Clear search',
                                  onPressed: () {
                                    widget.controller.clear();
                                    _hideOverlay();
                                    if (widget.onCleared != null) {
                                      widget.onCleared!();
                                    }
                                  },
                                )
                              : null),
                      contentPadding:
                          widget.contentPadding ?? const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
