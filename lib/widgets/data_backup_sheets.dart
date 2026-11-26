import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_backup_model.dart';
import '../providers/auth_provider.dart';
import '../providers/blacklist_provider.dart';
import '../providers/boards_provider.dart';
import '../providers/favorite_tags_provider.dart';
import '../providers/follows_provider.dart';
import '../providers/ref_boards_provider.dart';
import '../services/backup_service.dart';
import '../services/local_data_vault.dart';

T? _tryRead<T>(BuildContext context) {
  try {
    return Provider.of<T>(context, listen: false);
  } catch (_) {
    return null;
  }
}

String _formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

Future<void> _reloadAllProviders(BuildContext context) async {
  final auth = _tryRead<AuthProvider>(context);
  final blacklist = _tryRead<BlacklistProvider>(context);
  final boards = _tryRead<BoardsProvider>(context);
  final refBoards = _tryRead<RefBoardsProvider>(context);
  final favTags = _tryRead<FavoriteTagsProvider>(context);
  final follows = _tryRead<FollowsProvider>(context);

  await Future.wait([
    if (auth != null) auth.reloadFromStorage(),
    if (blacklist != null) blacklist.loadSettings(),
    if (boards != null) boards.reloadFromStorage(),
    if (refBoards != null) refBoards.reloadFromStorage(),
    if (favTags != null) favTags.reloadFromStorage(),
  ]);

  if (follows != null) {
    await follows.updateForUser(
      auth?.user?.name,
      isGuest: auth?.isGuestMode ?? false,
    );
    await follows.reloadFromStorage();
  }
}

/// Opens the Export Backup bottom sheet from Settings.
Future<void> showExportDataSheet(
  BuildContext context, {
  BackupFileIo? fileIo,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ExportBackupSheet(
      fileIo: fileIo ?? const PlatformBackupFileIo(),
    ),
  );
}

/// Starts the full `.skerbackup` import flow: pick file -> decrypt (if needed) ->
/// preview & choose Merge/Replace -> apply atomically.
Future<void> showImportDataFlow(
  BuildContext context, {
  BackupFileIo? fileIo,
}) async {
  final io = fileIo ?? const PlatformBackupFileIo();
  final messenger = ScaffoldMessenger.of(context);

  PickedBackupFile? picked;
  try {
    picked = await io.pickBackupFile();
  } catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: Colors.red[800],
        content: Text('Could not open file picker: $e'),
      ),
    );
    return;
  }

  if (picked == null || !context.mounted) return;

  BackupEnvelopeHeader header;
  try {
    header = BackupService.inspectBackupBytes(picked.bytes);
  } on BackupFormatException catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: Colors.red[800],
        content: Text(e.message),
      ),
    );
    return;
  }

  AppBackupPayload? decoded;
  if (!header.encrypted) {
    try {
      decoded = await BackupService.decodeBackupBytes(picked.bytes);
    } on BackupFormatException catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.red[800],
          content: Text(e.message),
        ),
      );
      return;
    }
  } else {
    decoded = await _promptAndDecryptBackup(context, picked.bytes, picked.name);
  }

  if (decoded == null || !context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ImportPreviewSheet(
      fileName: picked!.name,
      header: header,
      payload: decoded!,
    ),
  );
}

Future<AppBackupPayload?> _promptAndDecryptBackup(
  BuildContext context,
  dynamic bytes,
  String fileName,
) async {
  String? errorText;
  while (context.mounted) {
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _BackupPasswordDialog(
        fileName: fileName,
        initialError: errorText,
      ),
    );
    if (password == null) return null;

    try {
      return await BackupService.decodeBackupBytes(bytes, password: password);
    } on BackupFormatException catch (e) {
      if (e.type == BackupFormatErrorType.wrongPasswordOrCorrupted ||
          e.type == BackupFormatErrorType.passwordRequired) {
        errorText = e.message;
        continue;
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red[800],
            content: Text(e.message),
          ),
        );
      }
      return null;
    }
  }
  return null;
}

/// Lists automatic pre-update and pre-import snapshots stored in [LocalDataVault]
/// and lets the user restore one.
Future<void> showRecoverySnapshotsSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.grey[900],
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _RecoverySnapshotsSheet(),
  );
}

class _ExportBackupSheet extends StatefulWidget {
  final BackupFileIo fileIo;

  const _ExportBackupSheet({required this.fileIo});

  @override
  State<_ExportBackupSheet> createState() => _ExportBackupSheetState();
}

class _ExportBackupSheetState extends State<_ExportBackupSheet> {
  final TextEditingController _passwordCtrl = TextEditingController();
  final TextEditingController _confirmCtrl = TextEditingController();

  BackupCategorySelection _selection = const BackupCategorySelection();
  bool _encrypt = true; // Option A: ON by default
  bool _obscurePassword = true;
  bool _isExporting = false;
  String? _errorText;

  int _guestFavoritesCount = 0;
  int _followsCount = 0;
  bool _countsLoaded = false;

  @override
  void initState() {
    super.initState();
    final refBoards = _tryRead<RefBoardsProvider>(context);
    if (refBoards != null &&
        !refBoards.artistModeEnabled &&
        refBoards.refBoards.isEmpty) {
      _selection = const BackupCategorySelection(refBoards: false);
    }
    _loadAsyncCounts();
  }

  Future<void> _loadAsyncCounts() async {
    final auth = _tryRead<AuthProvider>(context);
    final follows = _tryRead<FollowsProvider>(context);
    final guestFavs = auth != null ? await auth.getGuestFavorites() : const [];
    final followMap = follows != null
        ? await follows.readAllFollowNamespaces()
        : const <String, List<dynamic>>{};
    final totalFollows =
        followMap.values.fold<int>(0, (sum, list) => sum + list.length);

    if (!mounted) return;
    setState(() {
      _guestFavoritesCount = guestFavs.length;
      _followsCount = totalFollows;
      _countsLoaded = true;
    });
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleExport() async {
    final effectiveEncrypt = _encrypt || _selection.credentials;
    final password = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;

    if (effectiveEncrypt) {
      if (password.length < 4) {
        setState(() {
          _errorText = 'Please enter a password of at least 4 characters.';
        });
        return;
      }
      if (password != confirm) {
        setState(() {
          _errorText = 'Passwords do not match.';
        });
        return;
      }
    }

    if (!_selection.hasAnySelected) {
      setState(() {
        _errorText = 'Select at least one category to export.';
      });
      return;
    }

    final auth = _tryRead<AuthProvider>(context);
    final blacklist = _tryRead<BlacklistProvider>(context);
    final boards = _tryRead<BoardsProvider>(context);
    final refBoards = _tryRead<RefBoardsProvider>(context);
    final favTags = _tryRead<FavoriteTagsProvider>(context);
    final follows = _tryRead<FollowsProvider>(context);

    if (auth == null ||
        blacklist == null ||
        boards == null ||
        refBoards == null ||
        favTags == null ||
        follows == null) {
      setState(() {
        _errorText = 'App data providers are not ready yet.';
      });
      return;
    }

    setState(() {
      _isExporting = true;
      _errorText = null;
    });

    try {
      final payload = await BackupService.collectBackupPayload(
        authProvider: auth,
        blacklistProvider: blacklist,
        boardsProvider: boards,
        refBoardsProvider: refBoards,
        favoriteTagsProvider: favTags,
        followsProvider: follows,
        selection: _selection,
      );

      final bytes = await BackupService.encodeBackup(
        payload,
        encrypt: effectiveEncrypt,
        password: effectiveEncrypt ? password : null,
      );

      final fileName = BackupService.suggestedFileName();
      final savedPath = await widget.fileIo.saveBackupFile(bytes, fileName);

      if (!mounted) return;
      if (savedPath == null) {
        setState(() => _isExporting = false);
        return;
      }

      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.green[800],
          content: Text(
            effectiveEncrypt
                ? 'Encrypted backup saved ($fileName)'
                : 'Backup saved ($fileName)',
          ),
        ),
      );
    } on BackupFormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _isExporting = false;
        _errorText = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isExporting = false;
        _errorText = 'Export failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = _tryRead<AuthProvider>(context);
    final blacklist = _tryRead<BlacklistProvider>(context);
    final boards = _tryRead<BoardsProvider>(context);
    final refBoards = _tryRead<RefBoardsProvider>(context);
    final favTags = _tryRead<FavoriteTagsProvider>(context);

    final isLoggedIn = auth?.isLoggedIn ?? false;
    final isArtistMode = refBoards?.artistModeEnabled ?? true;
    final hasRefBoards = refBoards?.refBoards.isNotEmpty ?? false;
    final showRefCanvasesRow = isArtistMode || hasRefBoards;
    final encryptionForced = _selection.credentials;
    final effectiveEncrypt = _encrypt || encryptionForced;

    return SafeArea(
      child: SingleChildScrollView(
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
            _SheetDragHandle(),
            const Text(
              'Export Data',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Creates a portable .skerbackup file of your local app data.',
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
            ),
            const SizedBox(height: 12),
            _CategoryCheckTile(
              title: 'Saved Boards',
              subtitle: '${boards?.boards.length ?? 0} boards',
              value: _selection.boards,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(boards: v),
              ),
            ),
            if (showRefCanvasesRow)
              _CategoryCheckTile(
                title: 'Reference Canvases',
                subtitle: !isArtistMode && hasRefBoards
                    ? '${refBoards!.refBoards.length} canvases (hidden while Artist Mode is off)'
                    : '${refBoards?.refBoards.length ?? 0} canvases',
                value: _selection.refBoards,
                onChanged: (v) => setState(
                  () => _selection = _selection.copyWith(refBoards: v),
                ),
              ),
            _CategoryCheckTile(
              title: 'Favorite Tags & Tag Sets',
              subtitle:
                  '${favTags?.totalTagCount ?? 0} tags, ${favTags?.sets.length ?? 0} sets',
              value: _selection.favoriteTags,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(favoriteTags: v),
              ),
            ),
            _CategoryCheckTile(
              title: 'Followed Pools & Sets',
              subtitle:
                  _countsLoaded ? '$_followsCount followed' : 'Loading...',
              value: _selection.follows,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(follows: v),
              ),
            ),
            _CategoryCheckTile(
              title: 'Guest Favorites',
              subtitle: _countsLoaded
                  ? '$_guestFavoritesCount saved posts'
                  : 'Loading...',
              value: _selection.guestFavorites,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(guestFavorites: v),
              ),
            ),
            _CategoryCheckTile(
              title: 'Blacklist & Filters',
              subtitle: '${blacklist?.ruleCount ?? 0} rules',
              value: _selection.blacklist,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(blacklist: v),
              ),
            ),
            _CategoryCheckTile(
              title: 'App Preferences',
              subtitle: 'Site host (${auth?.host ?? "e926.net"}) & settings',
              value: _selection.preferences,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(preferences: v),
              ),
            ),
            _CategoryCheckTile(
              title: 'Include Account Credentials (API Key)',
              subtitle: isLoggedIn
                  ? 'Forces password encryption ON'
                  : 'Not signed in',
              value: _selection.credentials,
              enabled: isLoggedIn,
              highlightWarning: true,
              onChanged: (v) => setState(() {
                _selection = _selection.copyWith(credentials: v);
                if (v) _encrypt = true;
              }),
            ),
            const Divider(color: Colors.white12, height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Encrypt with password',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                encryptionForced
                    ? 'Required when exporting API credentials'
                    : 'Recommended. Protects your backup with AES-256.',
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
              value: effectiveEncrypt,
              activeThumbColor: Theme.of(context).colorScheme.primary,
              onChanged: encryptionForced
                  ? null
                  : (val) => setState(() {
                        _encrypt = val;
                        _errorText = null;
                      }),
            ),
            if (effectiveEncrypt) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Backup password',
                  filled: true,
                  fillColor: Colors.black45,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _confirmCtrl,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Confirm password',
                  filled: true,
                  fillColor: Colors.black45,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'If you forget this password, the backup file cannot be recovered.',
                style: TextStyle(fontSize: 11, color: Colors.amber[300]),
              ),
            ],
            if (_errorText != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorText!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _isExporting ? null : _handleExport,
              icon: _isExporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_alt_rounded, size: 18),
              label: Text(
                _isExporting ? 'Exporting...' : 'Export Backup',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackupPasswordDialog extends StatefulWidget {
  final String fileName;
  final String? initialError;

  const _BackupPasswordDialog({
    required this.fileName,
    this.initialError,
  });

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.grey[900],
      title: const Text('Unlock Backup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter the password for "${widget.fileName}".',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: _obscure,
            onSubmitted: (val) => Navigator.of(context).pop(val),
            decoration: InputDecoration(
              labelText: 'Password',
              errorText: widget.initialError,
              filled: true,
              fillColor: Colors.black45,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}

class _ImportPreviewSheet extends StatefulWidget {
  final String fileName;
  final BackupEnvelopeHeader header;
  final AppBackupPayload payload;

  const _ImportPreviewSheet({
    required this.fileName,
    required this.header,
    required this.payload,
  });

  @override
  State<_ImportPreviewSheet> createState() => _ImportPreviewSheetState();
}

class _ImportPreviewSheetState extends State<_ImportPreviewSheet> {
  BackupImportMode _mode = BackupImportMode.merge;
  late BackupCategorySelection _selection;
  bool _isApplying = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final p = widget.payload;
    _selection = BackupCategorySelection(
      boards: p.hasBoardsSection,
      refBoards: p.hasRefBoardsSection,
      favoriteTags: p.hasFavoriteTagsSection,
      follows: p.hasFollowsSection,
      guestFavorites: p.hasGuestFavoritesSection,
      blacklist: p.hasBlacklist,
      preferences: p.hasPreferences,
      credentials: p.hasCredentials,
    );
  }

  Future<void> _handleImport() async {
    if (!_selection.hasAnySelected) {
      setState(() => _errorText = 'Select at least one category to import.');
      return;
    }

    if (_mode == BackupImportMode.replace) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Replace Existing Data?'),
          content: const Text(
            'Replace mode will overwrite your currently selected local data with the backup contents. An automatic safety snapshot will be saved first.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final auth = _tryRead<AuthProvider>(context);
    final blacklist = _tryRead<BlacklistProvider>(context);
    final boards = _tryRead<BoardsProvider>(context);
    final refBoards = _tryRead<RefBoardsProvider>(context);
    final favTags = _tryRead<FavoriteTagsProvider>(context);
    final follows = _tryRead<FollowsProvider>(context);
    final vault = _tryRead<LocalDataVault?>(context);

    if (auth == null ||
        blacklist == null ||
        boards == null ||
        refBoards == null ||
        favTags == null ||
        follows == null) {
      setState(() => _errorText = 'App data providers are not ready yet.');
      return;
    }

    setState(() {
      _isApplying = true;
      _errorText = null;
    });

    try {
      final summary = await BackupService.applyBackup(
        payload: widget.payload,
        mode: _mode,
        selection: _selection,
        vault: vault,
        authProvider: auth,
        blacklistProvider: blacklist,
        boardsProvider: boards,
        refBoardsProvider: refBoards,
        favoriteTagsProvider: favTags,
        followsProvider: follows,
      );

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final showCanvasCount = summary.refBoardsCount > 0 || refBoards.artistModeEnabled;
      final parts = <String>[
        '${summary.boardsCount} boards',
        if (showCanvasCount) '${summary.refBoardsCount} canvases',
        '${summary.favoriteTagsCount} tags',
        '${summary.followsCount} follows',
      ];
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.green[800],
          content: Text(
            'Import complete (${summary.mode == BackupImportMode.merge ? "merged" : "replaced"}): '
            '${parts.join(', ')}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isApplying = false;
        _errorText = 'Import failed (changes rolled back): $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    final refBoards = _tryRead<RefBoardsProvider>(context);
    final artistMode = refBoards?.artistModeEnabled ?? false;
    final showRefCanvasesRow = artistMode || p.refBoardCount > 0;

    return SafeArea(
      child: SingleChildScrollView(
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
            _SheetDragHandle(),
            const Text(
              'Import Backup Preview',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              '${widget.fileName} • Exported ${_formatDateTime(p.exportedAt)} (v${p.appVersion})',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
            const SizedBox(height: 12),
            SegmentedButton<BackupImportMode>(
              segments: const [
                ButtonSegment(
                  value: BackupImportMode.merge,
                  label: Text('Merge (Recommended)'),
                  icon: Icon(Icons.merge_type_rounded, size: 18),
                ),
                ButtonSegment(
                  value: BackupImportMode.replace,
                  label: Text('Replace All'),
                  icon: Icon(Icons.sync_alt_rounded, size: 18),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (sel) =>
                  setState(() => _mode = sel.first),
            ),
            if (_mode == BackupImportMode.replace) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.redAccent.withValues(alpha: 0.4),
                  ),
                ),
                child: const Text(
                  'Selected categories will overwrite existing local data. A recovery snapshot will be created automatically before importing.',
                  style: TextStyle(fontSize: 12, color: Colors.redAccent),
                ),
              ),
            ],
            const SizedBox(height: 10),
            _CategoryCheckTile(
              title: 'Saved Boards',
              subtitle: p.hasBoardsSection
                  ? '${p.boardCount} boards in backup'
                  : 'Not included in backup',
              value: _selection.boards,
              enabled: p.hasBoardsSection,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(boards: v),
              ),
            ),
            if (showRefCanvasesRow)
              _CategoryCheckTile(
                title: 'Reference Canvases',
                subtitle: p.hasRefBoardsSection
                    ? (!artistMode && p.refBoardCount > 0
                        ? '${p.refBoardCount} canvases in backup • Enable Artist Mode to view'
                        : '${p.refBoardCount} canvases in backup')
                    : 'Not included in backup',
                value: _selection.refBoards,
                enabled: p.hasRefBoardsSection,
                onChanged: (v) => setState(
                  () => _selection = _selection.copyWith(refBoards: v),
                ),
              ),
            _CategoryCheckTile(
              title: 'Favorite Tags & Tag Sets',
              subtitle: p.hasFavoriteTagsSection
                  ? '${p.favoriteTagCount} tags, ${p.favoriteTagSetCount} sets'
                  : 'Not included in backup',
              value: _selection.favoriteTags,
              enabled: p.hasFavoriteTagsSection,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(favoriteTags: v),
              ),
            ),
            _CategoryCheckTile(
              title: 'Followed Pools & Sets',
              subtitle: p.hasFollowsSection
                  ? '${p.followCount} followed collections'
                  : 'Not included in backup',
              value: _selection.follows,
              enabled: p.hasFollowsSection,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(follows: v),
              ),
            ),
            _CategoryCheckTile(
              title: 'Guest Favorites',
              subtitle: p.hasGuestFavoritesSection
                  ? '${p.guestFavoriteCount} posts'
                  : 'Not included in backup',
              value: _selection.guestFavorites,
              enabled: p.hasGuestFavoritesSection,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(guestFavorites: v),
              ),
            ),
            _CategoryCheckTile(
              title: 'Blacklist & Filters',
              subtitle: p.hasBlacklist
                  ? '${p.blacklistRuleCount} rules'
                  : 'Not included in backup',
              value: _selection.blacklist,
              enabled: p.hasBlacklist,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(blacklist: v),
              ),
            ),
            _CategoryCheckTile(
              title: 'App Preferences',
              subtitle: p.hasPreferences
                  ? 'Host: ${p.preferences!.siteHost}'
                  : 'Not included in backup',
              value: _selection.preferences,
              enabled: p.hasPreferences,
              onChanged: (v) => setState(
                () => _selection = _selection.copyWith(preferences: v),
              ),
            ),
            if (p.hasCredentials)
              _CategoryCheckTile(
                title: 'Account Credentials',
                subtitle: 'Account: ${p.credentials!.username}',
                value: _selection.credentials,
                highlightWarning: true,
                onChanged: (v) => setState(
                  () => _selection = _selection.copyWith(credentials: v),
                ),
              ),
            if (_errorText != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorText!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
            const SizedBox(height: 14),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _mode == BackupImportMode.replace
                    ? Colors.redAccent
                    : Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: _isApplying ? null : _handleImport,
              icon: _isApplying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.restore_rounded, size: 18),
              label: Text(
                _isApplying ? 'Importing...' : 'Import Data',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecoverySnapshotsSheet extends StatefulWidget {
  const _RecoverySnapshotsSheet();

  @override
  State<_RecoverySnapshotsSheet> createState() =>
      _RecoverySnapshotsSheetState();
}

class _RecoverySnapshotsSheetState extends State<_RecoverySnapshotsSheet> {
  List<VaultSnapshotInfo>? _snapshots;
  bool _isRestoring = false;

  @override
  void initState() {
    super.initState();
    _loadSnapshots();
  }

  Future<void> _loadSnapshots() async {
    final vault = _tryRead<LocalDataVault?>(context);
    if (vault == null) {
      setState(() => _snapshots = const []);
      return;
    }
    final list = await vault.listSnapshots();
    if (!mounted) return;
    setState(() => _snapshots = list);
  }

  Future<void> _restore(VaultSnapshotInfo info) async {
    final vault = _tryRead<LocalDataVault?>(context);
    if (vault == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Restore Snapshot?'),
        content: Text(
          'Restore "${info.displayReason}" from ${_formatDateTime(info.createdAt)}? Current local data will be replaced.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isRestoring = true);
    try {
      await vault.restoreSnapshot(info.id);
      if (!mounted) return;
      await _reloadAllProviders(context);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.green[800],
          content: Text('Restored ${info.displayReason}.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRestoring = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red[800],
          content: Text('Restore failed: $e'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final vault = _tryRead<LocalDataVault?>(context);
    final snapshots = _snapshots;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetDragHandle(),
            const Text(
              'Recovery Snapshots',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              vault != null
                  ? 'Vault schema v${vault.schemaVersion} • App ${vault.currentRuntimeAppVersion}'
                  : 'Encrypted vault unavailable in current context',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
            const SizedBox(height: 12),
            if (snapshots == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (snapshots.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'No automatic snapshots yet. Snapshots are created automatically before app updates and backup imports.',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: snapshots.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: Colors.white12, height: 1),
                  itemBuilder: (_, idx) {
                    final snap = snapshots[idx];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.history_rounded,
                        color: Colors.blueAccent,
                      ),
                      title: Text(
                        snap.displayReason,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${_formatDateTime(snap.createdAt)} • v${snap.appVersion}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                      ),
                      trailing: TextButton(
                        onPressed: _isRestoring ? null : () => _restore(snap),
                        child: const Text('Restore'),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryCheckTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final bool highlightWarning;
  final ValueChanged<bool> onChanged;

  const _CategoryCheckTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.highlightWarning = false,
  });

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: enabled ? value : false,
      onChanged: enabled ? (v) => onChanged(v ?? false) : null,
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: enabled ? Colors.white : Colors.grey[600],
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: highlightWarning && enabled
              ? Colors.amber[300]
              : Colors.grey[400],
        ),
      ),
    );
  }
}

class _SheetDragHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: Colors.grey[700],
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
