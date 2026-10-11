import 'dart:convert';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/board_model.dart';
import '../models/post_model.dart';

class BoardsProvider with ChangeNotifier {
  final FlutterSecureStorage _storage;
  List<Board> _boards = [];
  bool _isLoading = false;
  bool _isInitialized = false;
  String _currentStorageKey = 'boards_guest';

  BoardsProvider({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  List<Board> get boards => List.unmodifiable(_boards);
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String get currentStorageKey => _currentStorageKey;

  void _safeNotify() {
    try {
      if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          notifyListeners();
        });
        return;
      }
    } catch (_) {
      // Binding not initialized (e.g. running in pure unit test environment)
    }
    notifyListeners();
  }

  /// Updates the storage namespace for the current user or guest mode.
  Future<void> updateForUser(String? username, {bool isGuest = false}) async {
    final newKey = (username != null && username.isNotEmpty && !isGuest)
        ? 'boards_user_$username'
        : 'boards_guest';

    if (_currentStorageKey != newKey || !_isInitialized) {
      _currentStorageKey = newKey;
      _isInitialized = true;
      await loadBoards();
    }
  }

  /// Loads boards from secure storage
  Future<void> loadBoards() async {
    _isLoading = true;
    _safeNotify();

    try {
      final String? data = await _storage.read(key: _currentStorageKey);
      if (data != null && data.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(data);
        _boards = decoded
            .whereType<Map<String, dynamic>>()
            .map((e) => Board.fromJson(e))
            .toList();
        // Sort newest first
        _boards.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      } else {
        _boards = [];
      }
    } catch (e) {
      debugPrint('Error loading boards: $e');
      _boards = [];
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  /// Saves boards to secure storage
  Future<void> _persistBoards() async {
    try {
      final String encoded = jsonEncode(_boards.map((b) => b.toJson()).toList());
      await _storage.write(key: _currentStorageKey, value: encoded);
    } catch (e) {
      debugPrint('Error persisting boards: $e');
    }
  }

  /// Creates a new board, optionally adding an initial post immediately
  Future<Board> createBoard(String name, {E621Post? initialPost}) async {
    final trimmedName = name.trim().isEmpty ? 'New Board' : name.trim();
    final String id = DateTime.now().microsecondsSinceEpoch.toString();

    final List<int> postIds = initialPost != null ? [initialPost.id] : [];
    final List<E621Post> posts = initialPost != null ? [initialPost] : [];

    final newBoard = Board(
      id: id,
      name: trimmedName,
      createdAt: DateTime.now(),
      postIds: postIds,
      posts: posts,
    );

    _boards.insert(0, newBoard);
    await _persistBoards();
    notifyListeners();
    return newBoard;
  }

  /// Renames an existing board
  Future<bool> renameBoard(String boardId, String newName) async {
    final index = _boards.indexWhere((b) => b.id == boardId);
    if (index == -1) return false;

    final trimmed = newName.trim();
    if (trimmed.isEmpty) return false;

    _boards[index] = _boards[index].copyWith(name: trimmed);
    await _persistBoards();
    notifyListeners();
    return true;
  }

  /// Deletes a board
  Future<bool> deleteBoard(String boardId) async {
    final int initialLength = _boards.length;
    _boards.removeWhere((b) => b.id == boardId);
    if (_boards.length != initialLength) {
      await _persistBoards();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Adds a post to a board if it is not already in it
  Future<bool> addPostToBoard(String boardId, E621Post post) async {
    final index = _boards.indexWhere((b) => b.id == boardId);
    if (index == -1) return false;

    final board = _boards[index];
    if (board.postIds.contains(post.id)) {
      return false; // Already present
    }

    final updatedPostIds = [post.id, ...board.postIds];
    final updatedPosts = [post, ...board.posts.where((p) => p.id != post.id)];

    _boards[index] = board.copyWith(
      postIds: updatedPostIds,
      posts: updatedPosts,
    );

    await _persistBoards();
    notifyListeners();
    return true;
  }

  /// Removes a post from a board
  Future<bool> removePostFromBoard(String boardId, int postId) async {
    final index = _boards.indexWhere((b) => b.id == boardId);
    if (index == -1) return false;

    final board = _boards[index];
    if (!board.postIds.contains(postId)) {
      return false;
    }

    final updatedPostIds = board.postIds.where((id) => id != postId).toList();
    final updatedPosts = board.posts.where((p) => p.id != postId).toList();

    _boards[index] = board.copyWith(
      postIds: updatedPostIds,
      posts: updatedPosts,
    );

    await _persistBoards();
    notifyListeners();
    return true;
  }

  /// Toggles post presence in a board
  Future<bool> togglePostInBoard(String boardId, E621Post post) async {
    if (isPostInBoard(boardId, post.id)) {
      await removePostFromBoard(boardId, post.id);
      return false; // Now not in board
    } else {
      await addPostToBoard(boardId, post);
      return true; // Now in board
    }
  }

  /// Checks if a post is in a specific board
  bool isPostInBoard(String boardId, int postId) {
    final board = getBoardById(boardId);
    return board != null && board.postIds.contains(postId);
  }

  /// Returns all boards that contain a specific post
  List<Board> getBoardsContainingPost(int postId) {
    return _boards.where((b) => b.postIds.contains(postId)).toList();
  }

  /// Look up a board by ID
  Board? getBoardById(String boardId) {
    try {
      return _boards.firstWhere((b) => b.id == boardId);
    } catch (_) {
      return null;
    }
  }
}
