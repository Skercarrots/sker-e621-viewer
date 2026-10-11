import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../models/user_model.dart';
import '../models/post_model.dart';

class AuthProvider with ChangeNotifier {
  final FlutterSecureStorage _storage;
  final http.Client _client;
  E621User? _user;
  String? _username;
  String? _apiKey;
  bool _isLoading = false;
  bool _isGuestMode = false;

  AuthProvider({FlutterSecureStorage? storage, http.Client? client})
      : _storage = storage ?? const FlutterSecureStorage(),
        _client = client ?? http.Client();

  // --- NEW: Responsiveness Cache & Triggers ---
  int _favoritesUpdateTrigger = 0;
  final Set<int> _knownFavoriteIds = {}; 

  E621User? get user => _user;
  String? get username => _username;
  bool get isLoggedIn => _user != null && _apiKey != null;
  bool get isLoading => _isLoading;
  bool get isGuestMode => _isGuestMode;
  int get favoritesUpdateTrigger => _favoritesUpdateTrigger;

  Map<String, String> get authHeaders {
    if (_username != null && _apiKey != null) {
      final String basicAuth = 'Basic ${base64Encode(utf8.encode('$_username:$_apiKey'))}';
      return {
        'Authorization': basicAuth,
        'User-Agent': 'SkerE621/1.0 (by $_username on e621)', 
      };
    }
    return {'User-Agent': 'SkerE621/1.0 (by anonymous on e621)'};
  }

  Future<void> tryAutoLogin({bool refreshInBackground = true}) async {
    _isLoading = true;
    notifyListeners();

    try {
      final results = await Future.wait([
        _storage.read(key: 'username'),
        _storage.read(key: 'apiKey'),
        _storage.read(key: 'user_profile'),
        _storage.read(key: 'is_guest_mode'),
      ]);
      final storedUsername = results[0];
      final storedApiKey = results[1];
      final storedUserProfile = results[2];
      final storedGuestMode = results[3];

      if (storedUsername != null && storedApiKey != null) {
        _username = storedUsername;
        _apiKey = storedApiKey;
        _isGuestMode = false;

        if (storedUserProfile != null) {
          try {
            _user = E621User.fromJson(jsonDecode(storedUserProfile));
          } catch (e) {
            debugPrint('Error parsing cached user profile: $e');
          }
        }

        _isLoading = false;
        notifyListeners();

        // Refresh user profile in background without blocking session startup
        if (refreshInBackground) {
          _refreshUserDataInBackground(storedUsername);
        }
      } else if (storedGuestMode == 'true') {
        _isGuestMode = true;
        _isLoading = false;
        notifyListeners();
      } else {
        _isLoading = false;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error during tryAutoLogin: $e');
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshUserDataInBackground(String username) async {
    try {
      final uri = Uri.parse('https://e621.net/users/$username.json');
      final response = await _client.get(uri, headers: authHeaders);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final previousAvatarUrl = _user?.resolvedAvatarUrl;
        _user = E621User.fromJson(data);
        _user?.resolvedAvatarUrl ??= previousAvatarUrl;

        await resolveUserAvatar();

        if (_user != null) {
          await _storage.write(key: 'user_profile', value: jsonEncode(_user!.toJson()));
        }
        notifyListeners();
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        debugPrint('Credentials invalidated by server (${response.statusCode}). Logging out.');
        await logout();
      } else {
        debugPrint('Background user refresh returned status: ${response.statusCode}, keeping cached profile.');
      }
    } catch (e) {
      debugPrint('Background user refresh failed: $e, keeping cached session.');
    }
  }

  Future<bool> login(String username, String key) async {
    _isLoading = true;
    _isGuestMode = false;
    _knownFavoriteIds.clear(); // Clear cache on new login
    await _storage.delete(key: 'is_guest_mode');
    notifyListeners();

    try {
      _username = username;
      _apiKey = key;

      final uri = Uri.parse('https://e621.net/users/$username.json');
      final response = await _client.get(uri, headers: authHeaders);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _user = E621User.fromJson(data);

        await _storage.write(key: 'username', value: username);
        await _storage.write(key: 'apiKey', value: key);
        
        // If user has an avatar_id, resolve its real thumbnail URL
        await resolveUserAvatar();

        if (_user != null) {
          await _storage.write(key: 'user_profile', value: jsonEncode(_user!.toJson()));
        }

        _isLoading = false;
        notifyListeners();
        _notifyFavoritesChanged();
        return true;
      } else {
        _username = null;
        _apiKey = null;
        _user = null;
        _isLoading = false;
        notifyListeners();
        debugPrint('Login failed: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      _username = null;
      _apiKey = null;
      _user = null;
      _isLoading = false;
      notifyListeners();
      debugPrint('Login error: $e');
      return false;
    }
  }

  Future<void> logout() async {
    await _storage.delete(key: 'username');
    await _storage.delete(key: 'apiKey');
    await _storage.delete(key: 'user_profile');
    await _storage.delete(key: 'is_guest_mode');
    _user = null;
    _username = null;
    _apiKey = null;
    _isGuestMode = false;
    _knownFavoriteIds.clear(); // Clear cache on logout
    notifyListeners();
    _notifyFavoritesChanged();
  }

  Future<void> resolveUserAvatar() async {
    if (_user == null || _user!.avatarId == null || _user!.avatarId! <= 0) return;
    if (_user!.resolvedAvatarUrl != null) return;
    try {
      final postUri = Uri.https('e621.net', '/posts/${_user!.avatarId}.json', {'v2': 'true'});
      final postRes = await _client.get(postUri, headers: authHeaders);
      if (postRes.statusCode == 200) {
        final dynamic postData = json.decode(postRes.body);
        final Map<String, dynamic>? postMap = (postData is Map<String, dynamic>)
            ? (postData['post'] is Map<String, dynamic>
                ? postData['post'] as Map<String, dynamic>
                : postData)
            : null;
        if (postMap != null) {
          final post = E621Post.fromJson(postMap);
          _user!.resolvedAvatarUrl = post.previewUrl;
          if (_user != null) {
            await _storage.write(key: 'user_profile', value: jsonEncode(_user!.toJson()));
          }
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('Error resolving avatar: $e');
    }
  }

  // --- RESPONSIVENESS CACHE METHODS ---
  bool isKnownFavorite(int id) => _knownFavoriteIds.contains(id);

  void registerFavorites(List<int> ids) {
    _knownFavoriteIds.addAll(ids);
  }

  void markAsFavoriteLocally(int id) {
    _knownFavoriteIds.add(id);
  }

  void _notifyFavoritesChanged() {
    _favoritesUpdateTrigger++;
    notifyListeners();
  }

  // --- GUEST MODE METHODS ---
  Future<void> setGuestMode(bool value) async {
    _isGuestMode = value;
    if (value) {
      await _storage.write(key: 'is_guest_mode', value: 'true');
    } else {
      await _storage.delete(key: 'is_guest_mode');
    }
    _knownFavoriteIds.clear(); // Clear when toggling guest
    notifyListeners();
  }

  Future<List<E621Post>> getGuestFavorites() async {
    final String? data = await _storage.read(key: 'guest_favorites');
    if (data == null || data.isEmpty) return [];
    try {
      final List<dynamic> decoded = jsonDecode(data);
      final favs = decoded.map((e) => E621Post.fromLocalJson(e)).toList();
      // Auto-cache known favorites for instant UI loading later
      registerFavorites(favs.map((e) => e.id).toList());
      return favs;
    } catch (e) {
      return [];
    }
  }

  // Updated to use current state for Optimistic UI
  Future<bool> toggleGuestFavorite(E621Post post, bool isCurrentlyFav) async {
    List<E621Post> favs = await getGuestFavorites();
    
    if (isCurrentlyFav) {
      favs.removeWhere((p) => p.id == post.id);
      _knownFavoriteIds.remove(post.id);
    } else {
      if (!favs.any((p) => p.id == post.id)) favs.add(post);
      _knownFavoriteIds.add(post.id);
    }
    
    final String encoded = jsonEncode(favs.map((e) => e.toJson()).toList());
    await _storage.write(key: 'guest_favorites', value: encoded);
    
    _notifyFavoritesChanged();
    return true;
  }

  // --- API FAVORITE METHODS (For logged-in users) ---
  // Updated to use current state to avoid doing two API calls
  Future<bool> toggleApiFavorite(int postId, bool isCurrentlyFav) async {
    if (!isLoggedIn) return false;
    try {
      if (!isCurrentlyFav) {
        // We want to ADD it
        final uri = Uri.parse('https://e621.net/favorites.json');
        final response = await http.post(
          uri,
          headers: authHeaders,
          body: {'post_id': postId.toString()}
        );
        if (response.statusCode == 201 || response.statusCode == 200 || response.statusCode == 422) {
          _knownFavoriteIds.add(postId);
          _notifyFavoritesChanged();
          return true;
        }
      } else {
        // We want to REMOVE it
        final uriDelete = Uri.parse('https://e621.net/favorites/$postId.json');
        final delResponse = await http.delete(uriDelete, headers: authHeaders);
        if (delResponse.statusCode == 200 || delResponse.statusCode == 204) {
          _knownFavoriteIds.remove(postId);
          _notifyFavoritesChanged();
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint("API Fav Error: $e");
      return false;
    }
  }
}