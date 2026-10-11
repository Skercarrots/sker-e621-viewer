import 'dart:convert';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/collection_model.dart';
import '../services/e621_collections_api.dart';

class FollowsProvider with ChangeNotifier {
  final FlutterSecureStorage _storage;
  List<FollowedCollection> _follows = [];
  bool _isLoading = false;
  bool _isRefreshing = false;
  bool _isInitialized = false;
  String _currentStorageKey = 'follows_guest';

  FollowsProvider({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  List<FollowedCollection> get follows => List.unmodifiable(_follows);

  List<FollowedCollection> get followedPools =>
      _follows.where((f) => f.collection.isPool).toList();

  List<FollowedCollection> get followedSets =>
      _follows.where((f) => !f.collection.isPool).toList();

  int get totalNewCount =>
      _follows.fold<int>(0, (sum, item) => sum + item.newCount);

  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  bool get isInitialized => _isInitialized;

  void _safeNotify() {
    try {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          notifyListeners();
        });
        return;
      }
    } catch (_) {
      // Binding not initialized (e.g. unit tests)
    }
    notifyListeners();
  }

  /// Updates storage namespace based on logged in user or guest mode
  Future<void> updateForUser(String? username, {bool isGuest = false}) async {
    final newKey = (username != null && username.isNotEmpty && !isGuest)
        ? 'follows_user_$username'
        : 'follows_guest';

    if (_currentStorageKey != newKey || !_isInitialized) {
      _currentStorageKey = newKey;
      _isInitialized = true;
      await loadFollows();
    }
  }

  /// Loads followed collections from secure storage
  Future<void> loadFollows() async {
    _isLoading = true;
    _safeNotify();

    try {
      final String? data = await _storage.read(key: _currentStorageKey);
      if (data != null && data.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(data);
        _follows = decoded
            .whereType<Map<String, dynamic>>()
            .map((e) => FollowedCollection.fromJson(e))
            .toList();
        // Sort: items with new posts first, then newest followed
        _sortFollows();
      } else {
        _follows = [];
      }
    } catch (e) {
      debugPrint('Error loading follows: $e');
      _follows = [];
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  void _sortFollows() {
    _follows.sort((a, b) {
      if (a.newCount > 0 && b.newCount == 0) return -1;
      if (a.newCount == 0 && b.newCount > 0) return 1;
      return b.followedAt.compareTo(a.followedAt);
    });
  }

  Future<void> _persistFollows() async {
    try {
      final String encoded =
          jsonEncode(_follows.map((f) => f.toJson()).toList());
      await _storage.write(key: _currentStorageKey, value: encoded);
    } catch (e) {
      debugPrint('Error persisting follows: $e');
    }
  }

  bool isFollowing(CollectionType type, int id) {
    return _follows.any((f) => f.collection.type == type && f.collection.id == id);
  }

  FollowedCollection? getFollow(CollectionType type, int id) {
    try {
      return _follows.firstWhere(
        (f) => f.collection.type == type && f.collection.id == id,
      );
    } catch (_) {
      return null;
    }
  }

  /// Follow or unfollow a collection
  Future<bool> toggleFollow(E621Collection collection) async {
    final index = _follows.indexWhere(
      (f) => f.collection.type == collection.type && f.collection.id == collection.id,
    );

    if (index != -1) {
      // Unfollow
      _follows.removeAt(index);
      await _persistFollows();
      notifyListeners();
      return false;
    } else {
      // Follow - start with lastSeenCount equal to current postCount
      final newFollow = FollowedCollection(
        collection: collection,
        lastSeenCount: collection.postCount,
        followedAt: DateTime.now(),
      );
      _follows.insert(0, newFollow);
      _sortFollows();
      await _persistFollows();
      notifyListeners();
      return true;
    }
  }

  /// Marks a collection as seen, resetting its `newCount` badge
  Future<void> markSeen(CollectionType type, int id, int currentPostCount) async {
    final index = _follows.indexWhere(
      (f) => f.collection.type == type && f.collection.id == id,
    );
    if (index == -1) return;

    final existing = _follows[index];
    if (existing.lastSeenCount != currentPostCount) {
      _follows[index] = existing.copyWith(
        lastSeenCount: currentPostCount,
        collection: existing.collection.copyWith(postCount: currentPostCount),
      );
      _sortFollows();
      await _persistFollows();
      notifyListeners();
    }
  }

  /// Updates existing collection info in follows (e.g. coverUrl or postCount resolved elsewhere)
  Future<void> updateCollectionInfo(E621Collection updated) async {
    final index = _follows.indexWhere(
      (f) => f.collection.type == updated.type && f.collection.id == updated.id,
    );
    if (index == -1) return;

    final existing = _follows[index];
    _follows[index] = existing.copyWith(
      collection: updated,
    );
    await _persistFollows();
    notifyListeners();
  }

  /// Background refresh of all followed collections from the API to check for new posts
  Future<void> refreshFollowedCounts(E621CollectionsApi api) async {
    if (_isRefreshing || _follows.isEmpty) return;
    _isRefreshing = true;
    _safeNotify();

    try {
      final poolIds = _follows
          .where((f) => f.collection.isPool)
          .map((f) => f.collection.id)
          .toList();

      final setIds = _follows
          .where((f) => !f.collection.isPool)
          .map((f) => f.collection.id)
          .toList();

      final List<E621Collection> freshPools =
          poolIds.isNotEmpty ? await api.getPoolsByIds(poolIds) : [];
      final List<E621Collection> freshSets =
          setIds.isNotEmpty ? await api.getSetsByIds(setIds) : [];

      final allFresh = [...freshPools, ...freshSets];
      // Attach covers if any missing
      final withCovers = await api.attachCovers(allFresh);
      final freshMap = {for (var c in withCovers) c.key: c};

      bool changed = false;
      for (int i = 0; i < _follows.length; i++) {
        final current = _follows[i];
        final fresh = freshMap[current.collection.key];
        if (fresh != null) {
          // Merge cover URL if current had it and fresh doesn't or vice versa
          final coverUrl = fresh.coverUrl ?? current.collection.coverUrl;
          final updatedCol = fresh.copyWith(coverUrl: coverUrl);
          if (updatedCol.postCount != current.collection.postCount ||
              updatedCol.coverUrl != current.collection.coverUrl) {
            _follows[i] = current.copyWith(collection: updatedCol);
            changed = true;
          }
        }
      }

      if (changed) {
        _sortFollows();
        await _persistFollows();
      }
    } catch (e) {
      debugPrint('Error refreshing followed counts: $e');
    } finally {
      _isRefreshing = false;
      _safeNotify();
    }
  }
}

