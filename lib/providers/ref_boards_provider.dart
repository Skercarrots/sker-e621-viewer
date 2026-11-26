import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/ref_board_model.dart';
import '../models/board_model.dart';
import '../models/post_model.dart';
import '../services/local_data_vault.dart';

class RefBoardsProvider with ChangeNotifier {
  final FlutterSecureStorage _storage;
  final LocalDataVault? _vault;
  static const String _localStorageKey = 'ref_boards_local';
  static const String storageKeyArtistMode = 'artist_mode_enabled';
  List<RefBoard> _refBoards = [];
  bool _artistModeEnabled = false;
  bool _isLoading = false;
  bool _isInitialized = false;
  final Set<String> _migratedUsers = {};

  RefBoardsProvider({FlutterSecureStorage? storage, LocalDataVault? vault})
      : _storage = storage ?? const FlutterSecureStorage(),
        _vault = vault;

  Future<String?> _readKey(String key) async {
    if (_vault != null) {
      final fromVault = await _vault.read(key);
      if (fromVault != null) return fromVault;
    }
    return _storage.read(key: key);
  }

  Future<void> _writeKey(String key, String value) async {
    if (_vault != null) {
      await _vault.write(key, value);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  Future<void> reloadFromStorage() => loadRefBoards();

  List<RefBoard> get refBoards => List.unmodifiable(_refBoards);
  bool get artistModeEnabled => _artistModeEnabled;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String get currentStorageKey => _localStorageKey;

  /// Enables or disables Artist Mode (controls visibility of Ref Canvas UI).
  /// Existing Ref Canvases remain preserved in local storage when disabled.
  Future<void> setArtistModeEnabled(bool enabled) async {
    if (_artistModeEnabled == enabled) return;
    _artistModeEnabled = enabled;
    await _writeKey(storageKeyArtistMode, enabled ? 'true' : 'false');
    _safeNotify();
  }

  void _safeNotify() {
    try {
      if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          notifyListeners();
        });
        return;
      }
    } catch (_) {
      // Binding not initialized in isolated tests
    }
    notifyListeners();
  }

  /// Ensures reference boards are loaded. Since reference boards are local, they persist across guest and user sessions.
  Future<void> updateForUser(String? username, {bool isGuest = false}) async {
    if (!_isInitialized) {
      _isInitialized = true;
      await loadRefBoards();
    }

    if (username != null &&
        username.isNotEmpty &&
        !isGuest &&
        !_migratedUsers.contains(username)) {
      _migratedUsers.add(username);
      final legacyKey = 'ref_boards_user_$username';
      try {
        final legacyUserData = await _storage.read(key: legacyKey);
        if (legacyUserData != null && legacyUserData.isNotEmpty) {
          final List<dynamic> decoded = jsonDecode(legacyUserData);
          final userBoards = decoded
              .whereType<Map<String, dynamic>>()
              .map((e) => RefBoard.fromJson(e))
              .toList();

          bool hasChanges = false;
          final existingIds = _refBoards.map((b) => b.id).toSet();
          for (final ub in userBoards) {
            if (!existingIds.contains(ub.id)) {
              _refBoards.add(ub);
              hasChanges = true;
            }
          }
          if (hasChanges) {
            _refBoards.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
            await _persistBoards();
            final storedArtistMode = await _readKey(storageKeyArtistMode);
            if ((storedArtistMode == null || storedArtistMode.isEmpty) &&
                _refBoards.isNotEmpty) {
              _artistModeEnabled = true;
              await _writeKey(storageKeyArtistMode, 'true');
            }
            notifyListeners();
          }
          try {
            await _storage.delete(key: legacyKey);
          } catch (_) {
            await _storage.write(key: legacyKey, value: '');
          }
        }
      } catch (e) {
        debugPrint('Error merging legacy user ref boards: $e');
      }
    }
  }

  /// Loads reference boards from local storage
  Future<void> loadRefBoards() async {
    _isLoading = true;
    _safeNotify();

    try {
      String? data = await _readKey(_localStorageKey);

      // Migration fallback: if ref_boards_local is empty, import from legacy guest storage
      if (data == null || data.isEmpty) {
        final guestData = await _readKey('ref_boards_guest');
        if (guestData != null && guestData.isNotEmpty) {
          data = guestData;
          await _writeKey(_localStorageKey, data);
        }
      }

      if (data != null && data.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(data);
        _refBoards = decoded
            .whereType<Map<String, dynamic>>()
            .map((e) => RefBoard.fromJson(e))
            .toList();
        _refBoards.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      } else {
        _refBoards = [];
      }

      final storedArtistMode = await _readKey(storageKeyArtistMode);
      if (storedArtistMode != null && storedArtistMode.isNotEmpty) {
        _artistModeEnabled = storedArtistMode == 'true';
      } else if (_refBoards.isNotEmpty) {
        // Auto-enable for existing users who already have saved Ref Canvases.
        _artistModeEnabled = true;
        await _writeKey(storageKeyArtistMode, 'true');
      } else {
        _artistModeEnabled = false;
      }
    } catch (e) {
      debugPrint('Error loading ref boards: $e');
      _refBoards = [];
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  /// Persists reference boards to local storage
  Future<void> _persistBoards() async {
    try {
      final String encoded = jsonEncode(_refBoards.map((b) => b.toJson()).toList());
      await _writeKey(_localStorageKey, encoded);
    } catch (e) {
      debugPrint('Error persisting ref boards: $e');
    }
  }

  /// Helper to convert an E621Post into a RefBoardItem
  RefBoardItem _createItemFromPost(E621Post post, {double x = 0, double y = 0, int zIndex = 0}) {
    final imageUrl = post.fileUrl ?? post.previewUrl ?? '';
    return RefBoardItem(
      id: 'item_${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(9999)}',
      postId: post.id,
      imageUrl: imageUrl,
      previewUrl: post.previewUrl,
      x: x,
      y: y,
      width: 280.0,
      height: 380.0,
      rotation: 0.0,
      isFlippedH: false,
      isFlippedV: false,
      isGrayscale: false,
      zIndex: zIndex,
      post: post,
    );
  }

  /// Creates a new Ref Board, optionally populating with initial posts
  Future<RefBoard> createRefBoard(String name, {List<E621Post>? initialPosts}) async {
    final trimmedName = name.trim().isEmpty ? 'New Ref Board' : name.trim();
    final String id = '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(99999)}';
    final now = DateTime.now();

    final List<RefBoardItem> items = [];
    if (initialPosts != null && initialPosts.isNotEmpty) {
      const int cols = 3;
      const double itemW = 280.0;
      const double itemH = 380.0;
      const double spacing = 30.0;

      for (int i = 0; i < initialPosts.length; i++) {
        final col = i % cols;
        final row = i ~/ cols;
        final x = 50.0 + col * (itemW + spacing);
        final y = 50.0 + row * (itemH + spacing);
        items.add(_createItemFromPost(initialPosts[i], x: x, y: y, zIndex: i));
      }
    }

    final newBoard = RefBoard(
      id: id,
      name: trimmedName,
      createdAt: now,
      updatedAt: now,
      items: items,
      isLocked: false,
      backgroundColorHex: '#1E1E1E',
    );

    _refBoards.insert(0, newBoard);
    await _persistBoards();
    notifyListeners();
    return newBoard;
  }

  /// Creates a Ref Board directly from an existing saved Board
  Future<RefBoard> createFromSavedBoard(Board savedBoard) async {
    return createRefBoard('Ref: ${savedBoard.name}', initialPosts: savedBoard.posts);
  }

  /// Adds a single post to an existing Ref Board
  Future<bool> addPostToRefBoard(String boardId, E621Post post) async {
    final index = _refBoards.indexWhere((b) => b.id == boardId);
    if (index == -1) return false;

    final board = _refBoards[index];

    double targetX = 50.0;
    double targetY = 50.0;
    if (board.items.isNotEmpty) {
      double maxX = double.negativeInfinity;
      for (final item in board.items) {
        if (item.x + item.width > maxX) {
          maxX = item.x + item.width;
        }
      }
      targetX = maxX + 30.0;
      targetY = 50.0;
    }

    final maxZ = board.items.isEmpty
        ? 0
        : board.items.map((e) => e.zIndex).reduce(math.max) + 1;

    final newItem = _createItemFromPost(post, x: targetX, y: targetY, zIndex: maxZ);
    final updatedItems = [...board.items, newItem];

    _refBoards[index] = board.copyWith(
      items: updatedItems,
      updatedAt: DateTime.now(),
    );

    await _persistBoards();
    notifyListeners();
    return true;
  }

  /// Imports all posts from a saved board into a Ref Board and arranges them
  Future<int> addEntireBoardToRefBoard(String refBoardId, Board board) async {
    final index = _refBoards.indexWhere((b) => b.id == refBoardId);
    if (index == -1 || board.posts.isEmpty) return 0;

    final refBoard = _refBoards[index];
    final existingPostIds = refBoard.items.map((i) => i.postId).toSet();
    final postsToAdd = board.posts.where((p) => !existingPostIds.contains(p.id)).toList();

    if (postsToAdd.isEmpty) return 0;

    double startX = 50.0;
    if (refBoard.items.isNotEmpty) {
      double maxX = double.negativeInfinity;
      for (final item in refBoard.items) {
        if (item.x + item.width > maxX) {
          maxX = item.x + item.width;
        }
      }
      startX = maxX + 60.0;
    }

    const int cols = 3;
    const double itemW = 280.0;
    const double itemH = 380.0;
    const double spacing = 30.0;

    int currentMaxZ = refBoard.items.isEmpty
        ? 0
        : refBoard.items.map((e) => e.zIndex).reduce(math.max) + 1;

    final List<RefBoardItem> newItems = [];
    for (int i = 0; i < postsToAdd.length; i++) {
      final col = i % cols;
      final row = i ~/ cols;
      final x = startX + col * (itemW + spacing);
      final y = 50.0 + row * (itemH + spacing);
      newItems.add(_createItemFromPost(postsToAdd[i], x: x, y: y, zIndex: currentMaxZ + i));
    }

    _refBoards[index] = refBoard.copyWith(
      items: [...refBoard.items, ...newItems],
      updatedAt: DateTime.now(),
    );

    await _persistBoards();
    notifyListeners();
    return newItems.length;
  }

  /// Updates a specific item's coordinates, size, or transformations.
  /// Pass [persist] = `false` during continuous gestures and call [saveChanges] on end.
  Future<void> updateItemTransform(
    String boardId,
    String itemId, {
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    bool? isFlippedH,
    bool? isFlippedV,
    bool? isGrayscale,
    int? zIndex,
    bool persist = true,
  }) async {
    final bIndex = _refBoards.indexWhere((b) => b.id == boardId);
    if (bIndex == -1) return;

    final board = _refBoards[bIndex];
    final iIndex = board.items.indexWhere((i) => i.id == itemId);
    if (iIndex == -1) return;

    final current = board.items[iIndex];
    final updatedItem = current.copyWith(
      x: x,
      y: y,
      width: width,
      height: height,
      rotation: rotation,
      isFlippedH: isFlippedH,
      isFlippedV: isFlippedV,
      isGrayscale: isGrayscale,
      zIndex: zIndex,
    );

    final updatedItems = List<RefBoardItem>.from(board.items);
    updatedItems[iIndex] = updatedItem;

    _refBoards[bIndex] = board.copyWith(
      items: updatedItems,
      updatedAt: DateTime.now(),
    );

    if (persist) {
      await _persistBoards();
    }
    notifyListeners();
  }

  Future<void> saveChanges() => _persistBoards();

  Future<void> toggleItemFlipH(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null) return;
    final idx = board.items.indexWhere((i) => i.id == itemId);
    if (idx == -1) return;
    await updateItemTransform(boardId, itemId, isFlippedH: !board.items[idx].isFlippedH);
  }

  Future<void> toggleItemFlipV(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null) return;
    final idx = board.items.indexWhere((i) => i.id == itemId);
    if (idx == -1) return;
    await updateItemTransform(boardId, itemId, isFlippedV: !board.items[idx].isFlippedV);
  }

  Future<void> toggleItemGrayscale(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null) return;
    final idx = board.items.indexWhere((i) => i.id == itemId);
    if (idx == -1) return;
    await updateItemTransform(boardId, itemId, isGrayscale: !board.items[idx].isGrayscale);
  }

  Future<void> bringToFront(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null || board.items.isEmpty) return;

    final maxZ = board.items.map((e) => e.zIndex).reduce(math.max);
    await updateItemTransform(boardId, itemId, zIndex: maxZ + 1);
  }

  Future<void> sendToBack(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null || board.items.isEmpty) return;

    final minZ = board.items.map((e) => e.zIndex).reduce(math.min);
    await updateItemTransform(boardId, itemId, zIndex: minZ - 1);
  }

  Future<bool> removeItem(String boardId, String itemId) async {
    final bIndex = _refBoards.indexWhere((b) => b.id == boardId);
    if (bIndex == -1) return false;

    final board = _refBoards[bIndex];
    final updatedItems = board.items.where((i) => i.id != itemId).toList();
    if (updatedItems.length == board.items.length) return false;

    _refBoards[bIndex] = board.copyWith(
      items: updatedItems,
      updatedAt: DateTime.now(),
    );

    await _persistBoards();
    notifyListeners();
    return true;
  }

  Future<void> toggleBoardLock(String boardId) async {
    final bIndex = _refBoards.indexWhere((b) => b.id == boardId);
    if (bIndex == -1) return;

    final board = _refBoards[bIndex];
    _refBoards[bIndex] = board.copyWith(
      isLocked: !board.isLocked,
      updatedAt: DateTime.now(),
    );

    await _persistBoards();
    notifyListeners();
  }

  /// Auto-arranges all items on the canvas in a neat grid without overlapping.
  Future<void> autoArrangeBoard(String boardId, {int columns = 3, double spacing = 30.0}) async {
    final bIndex = _refBoards.indexWhere((b) => b.id == boardId);
    if (bIndex == -1) return;

    final board = _refBoards[bIndex];
    if (board.items.isEmpty) return;

    final List<RefBoardItem> arranged = [];
    final cols = math.max(1, columns);

    double currentY = 50.0;
    for (int rowStart = 0; rowStart < board.items.length; rowStart += cols) {
      double currentX = 50.0;
      double rowMaxHeight = 0.0;
      final rowEnd = math.min(rowStart + cols, board.items.length);

      for (int i = rowStart; i < rowEnd; i++) {
        final item = board.items[i];
        arranged.add(item.copyWith(
          x: currentX,
          y: currentY,
          rotation: 0.0,
          zIndex: i,
        ));
        currentX += item.width + spacing;
        if (item.height > rowMaxHeight) {
          rowMaxHeight = item.height;
        }
      }
      currentY += rowMaxHeight + spacing;
    }

    _refBoards[bIndex] = board.copyWith(
      items: arranged,
      updatedAt: DateTime.now(),
    );

    await _persistBoards();
    notifyListeners();
  }

  Future<bool> renameRefBoard(String boardId, String newName) async {
    final bIndex = _refBoards.indexWhere((b) => b.id == boardId);
    if (bIndex == -1) return false;

    final trimmed = newName.trim();
    if (trimmed.isEmpty) return false;

    _refBoards[bIndex] = _refBoards[bIndex].copyWith(
      name: trimmed,
      updatedAt: DateTime.now(),
    );

    await _persistBoards();
    notifyListeners();
    return true;
  }

  Future<bool> deleteRefBoard(String boardId) async {
    final initialLen = _refBoards.length;
    _refBoards.removeWhere((b) => b.id == boardId);
    if (_refBoards.length != initialLen) {
      await _persistBoards();
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<RefBoard?> duplicateRefBoard(String boardId) async {
    final original = getRefBoardById(boardId);
    if (original == null) return null;

    final now = DateTime.now();
    final rng = math.Random();
    final newId = '${now.microsecondsSinceEpoch}_${rng.nextInt(99999)}';
    final duplicatedItems = <RefBoardItem>[];
    for (int i = 0; i < original.items.length; i++) {
      duplicatedItems.add(
        original.items[i].copyWith(
          id: 'item_${now.microsecondsSinceEpoch}_${i}_${rng.nextInt(9999)}',
        ),
      );
    }

    final duplicate = RefBoard(
      id: newId,
      name: '${original.name} (Copy)',
      createdAt: now,
      updatedAt: now,
      items: duplicatedItems,
      isLocked: original.isLocked,
      backgroundColorHex: original.backgroundColorHex,
    );

    _refBoards.insert(0, duplicate);
    await _persistBoards();
    notifyListeners();
    return duplicate;
  }

  /// Imports a shared RefBoard (preserving all 2D item transforms and background settings)
  Future<RefBoard> importSharedRefBoard({
    required String name,
    required List<RefBoardItem> items,
    String backgroundColorHex = '#1E1E1E',
    bool isLocked = false,
  }) async {
    final now = DateTime.now();
    final trimmedName = name.trim().isEmpty ? 'Shared Ref Canvas' : name.trim();
    final newId = '${now.microsecondsSinceEpoch}_${math.Random().nextInt(99999)}';

    final clonedItems = <RefBoardItem>[];
    for (int i = 0; i < items.length; i++) {
      clonedItems.add(
        items[i].copyWith(
          id: 'item_${now.microsecondsSinceEpoch}_${i}_${math.Random().nextInt(9999)}',
        ),
      );
    }

    final imported = RefBoard(
      id: newId,
      name: trimmedName,
      createdAt: now,
      updatedAt: now,
      items: clonedItems,
      isLocked: isLocked,
      backgroundColorHex: backgroundColorHex,
    );

    _refBoards.insert(0, imported);
    await _persistBoards();
    notifyListeners();
    return imported;
  }

  RefBoard? getRefBoardById(String boardId) {
    try {
      return _refBoards.firstWhere((b) => b.id == boardId);
    } catch (_) {
      return null;
    }
  }
}
