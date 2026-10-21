import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/ref_board_model.dart';
import '../models/board_model.dart';
import '../models/post_model.dart';

class RefBoardsProvider with ChangeNotifier {
  final FlutterSecureStorage _storage;
  static const String _localStorageKey = 'ref_boards_local';
  List<RefBoard> _refBoards = [];
  bool _isLoading = false;
  bool _isInitialized = false;

  RefBoardsProvider({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  List<RefBoard> get refBoards => List.unmodifiable(_refBoards);
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String get currentStorageKey => _localStorageKey;

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

    // If logging into an existing user account, merge any legacy user boards if present
    if (username != null && username.isNotEmpty && !isGuest) {
      try {
        final legacyUserData = await _storage.read(key: 'ref_boards_user_$username');
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
            notifyListeners();
          }
        }
      } catch (e) {
        debugPrint('Error merging legacy user ref boards: $e');
      }
    }
  }

  /// Loads reference boards from local secure storage
  Future<void> loadRefBoards() async {
    _isLoading = true;
    _safeNotify();

    try {
      String? data = await _storage.read(key: _localStorageKey);

      // Migration fallback: if ref_boards_local is empty, import from legacy guest storage
      if (data == null || data.isEmpty) {
        final guestData = await _storage.read(key: 'ref_boards_guest');
        if (guestData != null && guestData.isNotEmpty) {
          data = guestData;
          await _storage.write(key: _localStorageKey, value: data);
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
    } catch (e) {
      debugPrint('Error loading ref boards: $e');
      _refBoards = [];
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  /// Persists reference boards to local secure storage
  Future<void> _persistBoards() async {
    try {
      final String encoded = jsonEncode(_refBoards.map((b) => b.toJson()).toList());
      await _storage.write(key: _localStorageKey, value: encoded);
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

    // Calculate smart placement position (to the right of the rightmost item, or below)
    double targetX = 50.0;
    double targetY = 50.0;
    if (board.items.isNotEmpty) {
      double maxX = 0;
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

    // Start placing after the rightmost edge of existing items
    double startX = 50.0;
    if (refBoard.items.isNotEmpty) {
      double maxX = 0;
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

  /// Updates a specific item's coordinates, size, or transformations
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

    await _persistBoards();
    notifyListeners();
  }

  /// Toggles horizontal flip (mirroring) on an item
  Future<void> toggleItemFlipH(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null) return;
    final item = board.items.firstWhere((i) => i.id == itemId, orElse: () => board.items.first);
    await updateItemTransform(boardId, itemId, isFlippedH: !item.isFlippedH);
  }

  /// Toggles vertical flip on an item
  Future<void> toggleItemFlipV(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null) return;
    final item = board.items.firstWhere((i) => i.id == itemId, orElse: () => board.items.first);
    await updateItemTransform(boardId, itemId, isFlippedV: !item.isFlippedV);
  }

  /// Toggles grayscale filter on an item
  Future<void> toggleItemGrayscale(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null) return;
    final item = board.items.firstWhere((i) => i.id == itemId, orElse: () => board.items.first);
    await updateItemTransform(boardId, itemId, isGrayscale: !item.isGrayscale);
  }

  /// Brings an item to the front of all items
  Future<void> bringToFront(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null || board.items.isEmpty) return;

    final maxZ = board.items.map((e) => e.zIndex).reduce(math.max);
    await updateItemTransform(boardId, itemId, zIndex: maxZ + 1);
  }

  /// Sends an item to the back
  Future<void> sendToBack(String boardId, String itemId) async {
    final board = getRefBoardById(boardId);
    if (board == null || board.items.isEmpty) return;

    final minZ = board.items.map((e) => e.zIndex).reduce(math.min);
    await updateItemTransform(boardId, itemId, zIndex: minZ - 1);
  }

  /// Removes an item from the canvas
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

  /// Toggles the lock status of the canvas items
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

  /// Auto-arranges all items on the canvas in a neat grid (smart grid layout)
  Future<void> autoArrangeBoard(String boardId, {int columns = 3, double spacing = 30.0}) async {
    final bIndex = _refBoards.indexWhere((b) => b.id == boardId);
    if (bIndex == -1) return;

    final board = _refBoards[bIndex];
    if (board.items.isEmpty) return;

    final List<RefBoardItem> arranged = [];
    final cols = math.max(1, columns);

    for (int i = 0; i < board.items.length; i++) {
      final item = board.items[i];
      final col = i % cols;
      final row = i ~/ cols;

      final x = 50.0 + col * (item.width + spacing);
      final y = 50.0 + row * (item.height + spacing);

      arranged.add(item.copyWith(
        x: x,
        y: y,
        rotation: 0.0,
        zIndex: i,
      ));
    }

    _refBoards[bIndex] = board.copyWith(
      items: arranged,
      updatedAt: DateTime.now(),
    );

    await _persistBoards();
    notifyListeners();
  }

  /// Renames an existing Ref Board
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

  /// Deletes a Ref Board
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

  /// Duplicates a Ref Board
  Future<RefBoard?> duplicateRefBoard(String boardId) async {
    final original = getRefBoardById(boardId);
    if (original == null) return null;

    final now = DateTime.now();
    final newId = '${now.microsecondsSinceEpoch}_${math.Random().nextInt(99999)}';
    final duplicatedItems = original.items
        .map((i) => i.copyWith(id: 'item_${now.microsecondsSinceEpoch}_${math.Random().nextInt(9999)}'))
        .toList();

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

  /// Look up a Ref Board by ID
  RefBoard? getRefBoardById(String boardId) {
    try {
      return _refBoards.firstWhere((b) => b.id == boardId);
    } catch (_) {
      return null;
    }
  }
}
