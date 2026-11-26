import 'dart:convert';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/favorite_tags_model.dart';
import '../services/local_data_vault.dart';

/// Manages user-favorited tags and custom Tag Sets locally on device.
class FavoriteTagsProvider with ChangeNotifier {
  final FlutterSecureStorage _storage;
  final LocalDataVault? _vault;
  static const String storageKey = 'favorite_tags_local';

  List<FavoriteTag> _tags = [];
  List<FavoriteTagSet> _sets = [];
  bool _isLoading = false;
  bool _isLoaded = false;

  FavoriteTagsProvider({FlutterSecureStorage? storage, LocalDataVault? vault})
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

  Future<void> reloadFromStorage() => load();

  List<FavoriteTag> get tags => List.unmodifiable(_tags);
  List<FavoriteTagSet> get sets => List.unmodifiable(_sets);
  int get totalTagCount => _tags.length;
  bool get isLoading => _isLoading;
  bool get isLoaded => _isLoaded;

  void _safeNotify() {
    try {
      if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          notifyListeners();
        });
        return;
      }
    } catch (_) {
      // Binding not initialized in isolated unit tests
    }
    notifyListeners();
  }

  String _generateUniqueSetId() {
    int candidate = DateTime.now().microsecondsSinceEpoch;
    while (_sets.any((s) => s.id == candidate.toString())) {
      candidate++;
    }
    return candidate.toString();
  }

  bool isFavorite(String rawTag) {
    final normalized = FavoriteTag.normalizeName(rawTag);
    if (normalized.isEmpty) return false;
    return _tags.any((t) => t.name == normalized);
  }

  FavoriteTag? getTag(String rawTag) {
    final normalized = FavoriteTag.normalizeName(rawTag);
    if (normalized.isEmpty) return null;
    for (final tag in _tags) {
      if (tag.name == normalized) return tag;
    }
    return null;
  }

  FavoriteTagSet? getSetById(String setId) {
    for (final set in _sets) {
      if (set.id == setId) return set;
    }
    return null;
  }

  bool isTagInSet(String setId, String rawTag) {
    final normalized = FavoriteTag.normalizeName(rawTag);
    if (normalized.isEmpty) return false;
    final set = getSetById(setId);
    return set != null && set.tagNames.contains(normalized);
  }

  List<FavoriteTagSet> getSetsContainingTag(String rawTag) {
    final normalized = FavoriteTag.normalizeName(rawTag);
    if (normalized.isEmpty) return const [];
    return _sets.where((s) => s.tagNames.contains(normalized)).toList();
  }

  List<FavoriteTag> getTagsForSet(String setId) {
    final set = getSetById(setId);
    if (set == null) return const [];
    return set.tagNames.map((name) {
      return getTag(name) ??
          FavoriteTag(
            name: name,
            category: FavoriteTag.inferCategory(name),
            createdAt: set.createdAt,
          );
    }).toList();
  }

  String buildQueryForSet(String setId) {
    final set = getSetById(setId);
    if (set == null || set.tagNames.isEmpty) return '';
    return set.tagNames.join(' ');
  }

  Future<void> load() async {
    _isLoading = true;
    _safeNotify();

    try {
      final raw = await _readKey(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final rawTags = decoded['tags'];
          final List<FavoriteTag> loadedTags = [];
          final Set<String> seenTags = {};
          if (rawTags is List) {
            for (final item in rawTags.whereType<Map<String, dynamic>>()) {
              final tag = FavoriteTag.fromJson(item);
              if (tag.name.isNotEmpty && seenTags.add(tag.name)) {
                loadedTags.add(tag);
              }
            }
          }

          final rawSets = decoded['sets'];
          final List<FavoriteTagSet> loadedSets = [];
          final Set<String> seenSetIds = {};
          if (rawSets is List) {
            for (final item in rawSets.whereType<Map<String, dynamic>>()) {
              final set = FavoriteTagSet.fromJson(item);
              if (set.id.isNotEmpty && set.name.isNotEmpty && seenSetIds.add(set.id)) {
                loadedSets.add(set);
              }
            }
          }

          _tags = loadedTags;
          _sets = loadedSets;
        } else {
          _tags = [];
          _sets = [];
        }
      } else {
        _tags = [];
        _sets = [];
      }
    } catch (e) {
      debugPrint('Error loading favorite tags: $e');
      _tags = [];
      _sets = [];
    } finally {
      _isLoading = false;
      _isLoaded = true;
      _safeNotify();
    }
  }

  Future<void> _persist() async {
    try {
      final encoded = jsonEncode({
        'version': 1,
        'tags': _tags.map((t) => t.toJson()).toList(),
        'sets': _sets.map((s) => s.toJson()).toList(),
      });
      await _writeKey(storageKey, encoded);
    } catch (e) {
      debugPrint('Error persisting favorite tags: $e');
    }
  }

  /// Adds a tag to favorites (or upgrades its category if previously unknown).
  /// Returns `true` if newly added, `false` if already present or invalid.
  Future<bool> addTag(String rawName, {int category = 0}) async {
    final normalized = FavoriteTag.normalizeName(rawName);
    if (normalized.isEmpty) return false;

    final effectiveCategory =
        category != 0 ? category : FavoriteTag.inferCategory(normalized);

    final existingIdx = _tags.indexWhere((t) => t.name == normalized);
    if (existingIdx != -1) {
      final existing = _tags[existingIdx];
      if (existing.category == 0 && effectiveCategory != 0) {
        _tags[existingIdx] = existing.copyWith(category: effectiveCategory);
        await _persist();
        _safeNotify();
      }
      return false;
    }

    _tags.insert(
      0,
      FavoriteTag(
        name: normalized,
        category: effectiveCategory,
        createdAt: DateTime.now(),
      ),
    );
    await _persist();
    _safeNotify();
    return true;
  }

  /// Removes a tag from favorites and from all Tag Sets.
  Future<bool> removeTag(String rawName) async {
    final normalized = FavoriteTag.normalizeName(rawName);
    if (normalized.isEmpty) return false;

    final initialLen = _tags.length;
    _tags.removeWhere((t) => t.name == normalized);
    bool changed = _tags.length != initialLen;

    for (int i = 0; i < _sets.length; i++) {
      final set = _sets[i];
      if (set.tagNames.contains(normalized)) {
        _sets[i] = set.copyWith(
          tagNames: set.tagNames.where((t) => t != normalized).toList(),
        );
        changed = true;
      }
    }

    if (!changed) return false;
    await _persist();
    _safeNotify();
    return true;
  }

  /// Toggles favorite status of [rawName]. Returns `true` if now favorited.
  Future<bool> toggleFavoriteTag(String rawName, {int category = 0}) async {
    if (isFavorite(rawName)) {
      await removeTag(rawName);
      return false;
    } else {
      await addTag(rawName, category: category);
      return true;
    }
  }

  /// Creates a new Tag Set, optionally seeding it with an initial tag.
  Future<FavoriteTagSet> createSet(
    String name, {
    String? initialTag,
    int initialTagCategory = 0,
  }) async {
    final trimmedName = name.trim().isEmpty ? 'New Set' : name.trim();
    final List<String> initialTags = [];

    if (initialTag != null) {
      final normalized = FavoriteTag.normalizeName(initialTag);
      if (normalized.isNotEmpty) {
        await addTag(normalized, category: initialTagCategory);
        initialTags.add(normalized);
      }
    }

    final newSet = FavoriteTagSet(
      id: _generateUniqueSetId(),
      name: trimmedName,
      tagNames: initialTags,
      createdAt: DateTime.now(),
    );

    _sets.insert(0, newSet);
    await _persist();
    _safeNotify();
    return newSet;
  }

  Future<bool> renameSet(String setId, String newName) async {
    final index = _sets.indexWhere((s) => s.id == setId);
    if (index == -1) return false;

    final trimmed = newName.trim();
    if (trimmed.isEmpty) return false;

    _sets[index] = _sets[index].copyWith(name: trimmed);
    await _persist();
    _safeNotify();
    return true;
  }

  Future<bool> deleteSet(String setId, {bool removeExclusiveTags = false}) async {
    final index = _sets.indexWhere((s) => s.id == setId);
    if (index == -1) return false;

    final removedSet = _sets.removeAt(index);
    if (removeExclusiveTags && removedSet.tagNames.isNotEmpty) {
      final remainingSetTags = <String>{};
      for (final s in _sets) {
        remainingSetTags.addAll(s.tagNames);
      }
      final exclusive = removedSet.tagNames
          .where((tag) => !remainingSetTags.contains(tag))
          .toSet();
      _tags.removeWhere((t) => exclusive.contains(t.name));
    }

    await _persist();
    _safeNotify();
    return true;
  }

  /// Adds [rawTagName] to favorites (if needed) and to [setId].
  /// Returns `true` if added to the set, `false` if already present or invalid.
  Future<bool> addTagToSet(
    String setId,
    String rawTagName, {
    int category = 0,
  }) async {
    final index = _sets.indexWhere((s) => s.id == setId);
    if (index == -1) return false;

    final normalized = FavoriteTag.normalizeName(rawTagName);
    if (normalized.isEmpty) return false;

    await addTag(normalized, category: category);

    final set = _sets[index];
    if (set.tagNames.contains(normalized)) {
      return false;
    }

    _sets[index] = set.copyWith(
      tagNames: [...set.tagNames, normalized],
    );
    await _persist();
    _safeNotify();
    return true;
  }

  /// Removes [rawTagName] from [setId] without removing it from general favorites.
  Future<bool> removeTagFromSet(String setId, String rawTagName) async {
    final index = _sets.indexWhere((s) => s.id == setId);
    if (index == -1) return false;

    final normalized = FavoriteTag.normalizeName(rawTagName);
    final set = _sets[index];
    if (!set.tagNames.contains(normalized)) return false;

    _sets[index] = set.copyWith(
      tagNames: set.tagNames.where((t) => t != normalized).toList(),
    );
    await _persist();
    _safeNotify();
    return true;
  }

  /// Toggles membership of [rawTagName] in [setId]. Returns `true` if added.
  Future<bool> toggleTagInSet(
    String setId,
    String rawTagName, {
    int category = 0,
  }) async {
    if (isTagInSet(setId, rawTagName)) {
      await removeTagFromSet(setId, rawTagName);
      return false;
    } else {
      await addTagToSet(setId, rawTagName, category: category);
      return true;
    }
  }
}
