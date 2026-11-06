import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/board_model.dart';
import '../models/ref_board_model.dart';
import '../pages/shared_board_preview_page.dart';
import '../services/board_share_service.dart';

/// Opens a bottom sheet with the generated Share Code and Deep Link for a [Board].
void showShareBoardSheet(
  BuildContext context,
  Board board, {
  String? author,
}) {
  final code = BoardShareService.encodeBoard(board, author: author);
  final deepLink = BoardShareService.buildDeepLink(code);
  final message = BoardShareService.buildShareMessage(
    name: board.name,
    itemCount: board.postCount,
    isRefCanvas: false,
    shareCode: code,
  );

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => _ShareOutputSheet(
      title: board.name,
      subtitle: '${board.postCount} ${board.postCount == 1 ? "art" : "arts"}',
      badgeLabel: 'SAVED BOARD',
      accentColor: Colors.blueAccent,
      shareCode: code,
      deepLink: deepLink,
      fullShareMessage: message,
    ),
  );
}

/// Opens a bottom sheet with the generated Share Code and Deep Link for a [RefBoard]
/// (preserving all 2D positions, sizes, flips, grayscale filters, and z-order).
void showShareRefCanvasSheet(
  BuildContext context,
  RefBoard refBoard, {
  String? author,
}) {
  final code = BoardShareService.encodeRefBoard(refBoard, author: author);
  final deepLink = BoardShareService.buildDeepLink(code);
  final message = BoardShareService.buildShareMessage(
    name: refBoard.name,
    itemCount: refBoard.itemCount,
    isRefCanvas: true,
    shareCode: code,
  );

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => _ShareOutputSheet(
      title: refBoard.name,
      subtitle:
          '${refBoard.itemCount} ${refBoard.itemCount == 1 ? "ref" : "refs"} • 2D Layout Included',
      badgeLabel: 'REF CANVAS',
      accentColor: Colors.cyanAccent,
      shareCode: code,
      deepLink: deepLink,
      fullShareMessage: message,
    ),
  );
}

/// Opens a bottom sheet that lets the user import a shared Board or Ref Canvas
/// via Share Code (`SKER-B1:...` / `SKER-R1:...`) or Deep Link (`sker://share?...`),
/// with automatic clipboard detection.
void showImportSharedModal(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => const _ImportSharedSheet(),
  );
}

class _ShareOutputSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final String badgeLabel;
  final Color accentColor;
  final String shareCode;
  final String deepLink;
  final String fullShareMessage;

  const _ShareOutputSheet({
    required this.title,
    required this.subtitle,
    required this.badgeLabel,
    required this.accentColor,
    required this.shareCode,
    required this.deepLink,
    required this.fullShareMessage,
  });

  @override
  State<_ShareOutputSheet> createState() => _ShareOutputSheetState();
}

class _ShareOutputSheetState extends State<_ShareOutputSheet> {
  String? _copiedKind;

  Future<void> _copy(String text, String kind, String feedback) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copiedKind = kind);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(feedback),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCyan = widget.accentColor == Colors.cyanAccent;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Icon(
                  isCyan ? Icons.draw_rounded : Icons.collections_bookmark_outlined,
                  color: widget.accentColor,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  widget.subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey[800]!),
              ),
              child: Text(
                widget.shareCode,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.white70,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.accentColor,
                      foregroundColor: isCyan ? Colors.black : Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: Icon(
                      _copiedKind == 'code' ? Icons.check_rounded : Icons.copy_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _copiedKind == 'code' ? 'Copied!' : 'Copy Code',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => _copy(
                      widget.shareCode,
                      'code',
                      'Code copied!',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.grey[700]!),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: Icon(
                      _copiedKind == 'message' ? Icons.check_rounded : Icons.link_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _copiedKind == 'message' ? 'Copied!' : 'Copy Link',
                    ),
                    onPressed: () => _copy(
                      widget.deepLink,
                      'message',
                      'Link copied!',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportSharedSheet extends StatefulWidget {
  const _ImportSharedSheet();

  @override
  State<_ImportSharedSheet> createState() => _ImportSharedSheetState();
}

class _ImportSharedSheetState extends State<_ImportSharedSheet> {
  final TextEditingController _controller = TextEditingController();
  SharedBoardPayload? _detectedClipboardPayload;
  String? _detectedClipboardRaw;
  SharedBoardPayload? _typedPayload;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _checkClipboardAutomatically();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _checkClipboardAutomatically() async {
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text?.trim();
      if (text != null && text.isNotEmpty) {
        final decoded = BoardShareService.tryDecodeAny(text);
        if (decoded != null && mounted) {
          setState(() {
            _detectedClipboardPayload = decoded;
            _detectedClipboardRaw = text;
          });
        }
      }
    } catch (_) {
      // Clipboard may not be accessible without user gesture on some platforms
    }
  }

  void _onTextChanged() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _typedPayload = null;
        _errorText = null;
      });
      return;
    }

    final decoded = BoardShareService.tryDecodeAny(raw);
    setState(() {
      _typedPayload = decoded;
      _errorText = decoded == null ? 'Invalid code or link' : null;
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      _controller.text = text;
    }
  }

  void _openPreview(SharedBoardPayload payload) {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(
      MaterialPageRoute(
        builder: (_) => SharedBoardPreviewPage(payload: payload),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activePayload = _typedPayload ??
        (_controller.text.isEmpty ? _detectedClipboardPayload : null);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Import',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLines: 1,
              decoration: InputDecoration(
                hintText: 'Paste share code or link...',
                hintStyle: TextStyle(fontSize: 13, color: Colors.grey[500]),
                errorText: _errorText,
                filled: true,
                fillColor: Colors.black45,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste_rounded, size: 20),
                  tooltip: 'Paste',
                  onPressed: _pasteFromClipboard,
                ),
              ),
            ),
            if (activePayload != null) ...[
              const SizedBox(height: 12),
              _buildDetectedCard(
                activePayload,
                isFromClipboard: _typedPayload == null,
              ),
            ],
            const SizedBox(height: 14),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: activePayload?.isRefCanvas == true
                    ? Colors.cyanAccent
                    : Theme.of(context).colorScheme.primary,
                foregroundColor:
                    activePayload?.isRefCanvas == true ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: activePayload != null
                  ? () => _openPreview(activePayload)
                  : null,
              child: const Text(
                'Open',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetectedCard(SharedBoardPayload payload, {required bool isFromClipboard}) {
    final isRef = payload.isRefCanvas;
    final accent = isRef ? Colors.cyanAccent : Colors.blueAccent;
    final unit = isRef
        ? (payload.itemCount == 1 ? 'ref' : 'refs')
        : (payload.itemCount == 1 ? 'art' : 'arts');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            isRef ? Icons.draw_rounded : Icons.collections_bookmark_outlined,
            color: accent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${payload.name} (${payload.itemCount} $unit)',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isFromClipboard && _detectedClipboardRaw != null)
            Text(
              'Clipboard',
              style: TextStyle(fontSize: 11, color: accent),
            ),
        ],
      ),
    );
  }
}

