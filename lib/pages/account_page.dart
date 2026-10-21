import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';
import '../providers/boards_provider.dart';
import '../models/post_model.dart';
import 'details_page.dart';
import 'settings_page.dart';
import 'login_page.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  final ScrollController _uploadsScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  
  final List<E621Post> _favPosts = [];
  bool _isLoadingFavs = false;
  int _favPage = 1;
  bool _hasMore = true; 
  int _lastFavVersion = 0; 

  // --- Uploads State ---
  final List<E621Post> _uploadedPosts = [];
  bool _isLoadingUploads = false;
  int _uploadPage = 1;
  bool _hasMoreUploads = true;
  String? _lastUploadsUser;

  // Hero tag prefixes (separate per grid so tags never collide).
  static const String _favHeroPrefix = 'account-favs';
  static const String _uploadsHeroPrefix = 'account-uploads';

  // NEW: Session-based dismissal of the guest warning
  bool _isWarningDismissed = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    
    final auth = Provider.of<AuthProvider>(context, listen: false);
    _lastFavVersion = auth.favoritesUpdateTrigger;

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent * 0.8) {
        if (!_isLoadingFavs && _hasMore) {
          _fetchFavorites();
        }
      }
    });

    _uploadsScrollController.addListener(() {
      if (_uploadsScrollController.hasClients &&
          _uploadsScrollController.position.pixels >= _uploadsScrollController.position.maxScrollExtent * 0.8) {
        if (!_isLoadingUploads && _hasMoreUploads) {
          _fetchUploads();
        }
      }
    });

    _tabController.addListener(() {
      if (_tabController.index == 1 && _uploadedPosts.isEmpty && !_isLoadingUploads && _hasMoreUploads) {
        final currentAuth = Provider.of<AuthProvider>(context, listen: false);
        if (currentAuth.isLoggedIn && currentAuth.user != null) {
          _fetchUploads();
        }
      }
    });

    _initializeData();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _uploadsScrollController.dispose();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _initializeData() {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final boards = Provider.of<BoardsProvider>(context, listen: false);
    boards.updateForUser(auth.user?.name, isGuest: auth.isGuestMode);

    if ((auth.isLoggedIn && auth.user != null) || auth.isGuestMode) {
      _fetchFavorites();
      if (auth.isLoggedIn && auth.user != null) {
        _fetchUploads();
      }
    } else {
      void listener() {
        if ((auth.isLoggedIn && auth.user != null) || auth.isGuestMode) {
          boards.updateForUser(auth.user?.name, isGuest: auth.isGuestMode);
          _fetchFavorites();
          if (auth.isLoggedIn && auth.user != null) {
            _fetchUploads();
          }
          auth.removeListener(listener);
        }
      }
      auth.addListener(listener);
    }
  }

  Future<void> _refreshFavorites({String? query}) async {
    if (query != null) {
      _searchController.text = query;
    }
    setState(() {
      _favPosts.clear();
      _favPage = 1;
      _hasMore = true;
    });
    await _fetchFavorites();
  }

  Future<void> _fetchFavorites({String? query}) async {
    if (_isLoadingFavs) return;
    if (query != null) {
      _searchController.text = query;
    }
    final auth = Provider.of<AuthProvider>(context, listen: false);
    
    // If not logged in and not guest, clear the list and stop
    if (!auth.isLoggedIn && !auth.isGuestMode) {
      setState(() => _favPosts.clear());
      return;
    }
    
    if (auth.isLoggedIn && auth.user == null) return;

    setState(() => _isLoadingFavs = true);

    try {
      final String searchText = _searchController.text.trim();
      if (auth.isGuestMode) {
        List<E621Post> localFavs = await auth.getGuestFavorites();
        localFavs = localFavs.reversed.toList();

        if (searchText.isNotEmpty) {
           final searchTerms = searchText.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
           localFavs = localFavs.where((post) {
             return searchTerms.every((term) => 
               post.generalTags.any((t) => t.toLowerCase().contains(term)) || 
               post.artistTags.any((t) => t.toLowerCase().contains(term)) ||
               post.characterTags.any((t) => t.toLowerCase().contains(term)) ||
               post.speciesTags.any((t) => t.toLowerCase().contains(term)) ||
               post.copyrightTags.any((t) => t.toLowerCase().contains(term))
             );
           }).toList();
        }
        
        int start = (_favPage - 1) * 20;
        int end = start + 20;
        
        if (start >= localFavs.length) {
           setState(() { _hasMore = false; });
        } else {
           List<E621Post> paged = localFavs.sublist(start, end > localFavs.length ? localFavs.length : end);
           setState(() {
              _favPosts.addAll(paged);
              _favPage++;
              _hasMore = end < localFavs.length;
           });
        }
      } else {
        final int userId = auth.user!.id;
        final Uri uri;

        if (searchText.isNotEmpty) {
          final String searchTags = "fav:${auth.user!.name} $searchText order:favat";
          uri = Uri.https(
            'e621.net',
            '/posts.json',
            {
              'tags': searchTags,
              'page': '$_favPage',
              'limit': '20',
              'v2': 'true',
              'mode': 'extended',
            },
          );
        } else {
          uri = Uri.https(
            'e621.net',
            '/favorites.json',
            {
              'user_id': '$userId',
              'page': '$_favPage',
              'limit': '20',
              'v2': 'true',
              'mode': 'extended',
            },
          );
        }

        final response = await http.get(uri, headers: auth.authHeaders);

        if (response.statusCode == 200) {
          final dynamic data = json.decode(response.body);
          final List<dynamic> postsJson = (data is List)
              ? data
              : (data is Map && data['posts'] is List ? data['posts'] as List<dynamic> : []);
          
          final newPosts = postsJson
              .whereType<Map<String, dynamic>>()
              .map((json) => E621Post.fromJson(json))
              .where((post) => post.previewUrl != null)
              .toList();

          auth.registerFavorites(newPosts.map((p) => p.id).toList());

          setState(() {
            if (newPosts.isEmpty) {
              _hasMore = false;
            } else {
              _favPosts.addAll(newPosts);
              _favPage++;
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Error: $e');
    } finally {
      if (mounted) setState(() => _isLoadingFavs = false);
    }
  }

  Future<void> _refreshUploads() async {
    setState(() {
      _uploadedPosts.clear();
      _uploadPage = 1;
      _hasMoreUploads = true;
    });
    await _fetchUploads();
  }

  Future<void> _fetchUploads() async {
    if (_isLoadingUploads) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);

    if (!auth.isLoggedIn || auth.user == null) {
      setState(() => _uploadedPosts.clear());
      return;
    }

    setState(() => _isLoadingUploads = true);
    _lastUploadsUser = auth.user!.name;

    if (auth.user!.resolvedAvatarUrl == null && auth.user!.avatarId != null && auth.user!.avatarId! > 0) {
      auth.resolveUserAvatar();
    }

    try {
      final uri = Uri.https(
        'e621.net',
        '/posts.json',
        {
          'tags': 'user:${auth.user!.name}',
          'page': '$_uploadPage',
          'limit': '30',
          'v2': 'true',
          'mode': 'extended',
        },
      );

      final response = await http.get(uri, headers: auth.authHeaders);

      if (response.statusCode == 200) {
        final dynamic data = json.decode(response.body);
        final List<dynamic> postsJson = (data is List)
            ? data
            : (data is Map && data['posts'] is List ? data['posts'] as List<dynamic> : []);

        final newPosts = postsJson
            .whereType<Map<String, dynamic>>()
            .map((json) => E621Post.fromJson(json))
            .where((post) => post.previewUrl != null)
            .toList();

        setState(() {
          if (newPosts.isEmpty) {
            _hasMoreUploads = false;
          } else {
            _uploadedPosts.addAll(newPosts);
            _uploadPage++;
            if (newPosts.length < 30) {
              _hasMoreUploads = false;
            }
          }
        });
      } else {
        setState(() => _hasMoreUploads = false);
      }
    } catch (e) {
      debugPrint('Error fetching uploads: $e');
    } finally {
      if (mounted) setState(() => _isLoadingUploads = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);

    // If version changed, it means user unlinked or changed status
    if (_lastFavVersion != authProvider.favoritesUpdateTrigger) {
      _lastFavVersion = authProvider.favoritesUpdateTrigger;
      
      final boards = Provider.of<BoardsProvider>(context, listen: false);
      boards.updateForUser(authProvider.user?.name, isGuest: authProvider.isGuestMode);

      // Clear current list immediately if they logged out/unlinked
      if (!authProvider.isLoggedIn && !authProvider.isGuestMode) {
        _favPosts.clear();
        _uploadedPosts.clear();
        _searchController.clear();
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _refreshFavorites();
          if (authProvider.isLoggedIn && authProvider.user != null) {
            _refreshUploads();
          }
        }
      });
    }

    if (authProvider.isLoggedIn &&
        authProvider.user != null &&
        authProvider.user!.name != _lastUploadsUser) {
      _lastUploadsUser = authProvider.user!.name;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshUploads();
      });
    }

    if (authProvider.isLoading && !authProvider.isLoggedIn && !authProvider.isGuestMode) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!authProvider.isLoggedIn && !authProvider.isGuestMode) {
      return _buildLoggedOutView(context);
    }

    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: CircleAvatar(
            backgroundColor: Colors.blueGrey,
            backgroundImage: (!authProvider.isGuestMode && authProvider.user?.resolvedAvatarUrl != null)
                ? CachedNetworkImageProvider(authProvider.user!.resolvedAvatarUrl!)
                : null,
            child: (authProvider.isGuestMode || authProvider.user?.resolvedAvatarUrl == null)
                ? Text(
                    authProvider.isGuestMode 
                      ? "G" 
                      : (authProvider.user?.name.isNotEmpty == true ? authProvider.user!.name[0].toUpperCase() : "?"),
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  )
                : null,
          ),
        ),
        title: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: Colors.white,
          dividerColor: Colors.transparent,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: "Favorites"),
            Tab(text: "My Uploads"),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context, 
              MaterialPageRoute(builder: (context) => const SettingsPage())
            ),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildFavsTab(authProvider),
          _buildUploadsTab(context, authProvider),
        ],
      ),
    );
  }

  Widget _buildFavsTab(AuthProvider auth) {
    if (auth.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    Widget guestWarning = const SizedBox.shrink();
    // Only show warning if in Guest Mode and not dismissed for this session
    if (auth.isGuestMode && !_isWarningDismissed) {
      guestWarning = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orangeAccent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.5), width: 1),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: Colors.orangeAccent, size: 18),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                "Guest Mode: Global blacklist is active.",
                style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16, color: Colors.orangeAccent),
              onPressed: () => setState(() => _isWarningDismissed = true),
            )
          ],
        ),
      );
    }

    final searchBar = Padding(
      padding: const EdgeInsets.all(12.0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(25),
        ),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) {
            final hasText = value.text.isNotEmpty;
            return TextField(
              controller: _searchController,
              onSubmitted: (val) => _refreshFavorites(query: val),
              decoration: InputDecoration(
                hintText: 'Search my favorites',
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                suffixIcon: hasText
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          _refreshFavorites(query: '');
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            );
          },
        ),
      ),
    );

    Widget content;
    if (_isLoadingFavs && _favPosts.isEmpty) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_favPosts.isEmpty) {
      final isSearching = _searchController.text.trim().isNotEmpty;
      content = LayoutBuilder(
        builder: (context, constraints) => RefreshIndicator(
          onRefresh: () async {
            await _refreshFavorites();
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isSearching ? Icons.search_off : Icons.favorite_border,
                        size: 64,
                        color: Colors.grey[600],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        isSearching
                            ? 'No favorites found matching\n"${_searchController.text.trim()}"'
                            : "No favorites found.",
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16, color: Colors.white70),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          if (isSearching)
                            OutlinedButton.icon(
                              icon: const Icon(Icons.clear, size: 18),
                              label: const Text("Clear search"),
                              onPressed: () {
                                _searchController.clear();
                                _refreshFavorites(query: '');
                              },
                            ),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text("Try again"),
                            onPressed: () => _refreshFavorites(),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      content = RefreshIndicator(
        onRefresh: () async {
          await _refreshFavorites();
        },
        child: GridView.builder(
          controller: _scrollController, 
          padding: const EdgeInsets.symmetric(horizontal: 8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.8,
          ),
          itemCount: _favPosts.length + (_hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _favPosts.length) {
              return const Center(child: CircularProgressIndicator());
            }
            final post = _favPosts[index];
            return GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PostDetailPage(
                    post: post,
                    posts: _favPosts,
                    initialIndex: index,
                    onLoadMore: _hasMore ? () => _fetchFavorites(query: _searchController.text.trim()) : null,
                    heroTagPrefix: _favHeroPrefix,
                  ),
                ),
              ),
              child: Hero(
                tag: postHeroTag(_favHeroPrefix, index, post),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: CachedNetworkImage(
                    imageUrl: post.previewUrl ?? '',
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Container(color: Colors.grey[850]),
                    errorWidget: (context, url, error) => const Icon(Icons.broken_image),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    return Column(
      children: [
        guestWarning,
        searchBar,
        Expanded(child: content),
      ],
    );
  }




  Widget _buildLoggedOutView(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.public_off, size: 80, color: Colors.grey),
            const SizedBox(height: 24),
            const Text(
              "Account Recommended", 
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)
            ),
            const SizedBox(height: 16),
            const Text(
              "Link your e621 account to access your favorites and bypass the e621 global blacklist, which hides certain content for guests.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const LoginPage())),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text("LINK ACCOUNT"),
            ),
            const SizedBox(height: 32),
            const Divider(color: Colors.white24),
            const SizedBox(height: 24),
            const Text(
              "Don't have an account or prefer not to link one?",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                // Reset dismissal state when entering Guest mode
                setState(() => _isWarningDismissed = false);
                auth.setGuestMode(true);
              },
              child: const Text("Continue as Guest (Filtered Content)", style: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }

  // --- UPLOADS TAB (Creator Feed) ---
  Widget _buildUploadsTab(BuildContext context, AuthProvider auth) {
    if (auth.isGuestMode || !auth.isLoggedIn || auth.user == null) {
      return _buildGuestUploadsPrompt(context);
    }

    return RefreshIndicator(
      onRefresh: _refreshUploads,
      child: CustomScrollView(
        controller: _uploadsScrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _buildCreatorProfileHeader(auth),
          ),
          SliverToBoxAdapter(
            child: _buildFeedDivider(),
          ),
          if (_isLoadingUploads && _uploadedPosts.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_uploadedPosts.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _buildEmptyUploadsView(),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.all(2.0),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 3.0,
                  mainAxisSpacing: 3.0,
                  childAspectRatio: 1.0,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final post = _uploadedPosts[index];
                    final isVideo = post.extension == 'webm' || post.extension == 'mp4';

                    return GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PostDetailPage(
                            post: post,
                            posts: _uploadedPosts,
                            initialIndex: index,
                            onLoadMore: _hasMoreUploads ? _fetchUploads : null,
                            heroTagPrefix: _uploadsHeroPrefix,
                          ),
                        ),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Hero(
                            tag: postHeroTag(_uploadsHeroPrefix, index, post),
                            child: CachedNetworkImage(
                              imageUrl: post.previewUrl!,
                              fit: BoxFit.cover,
                              placeholder: (context, url) => Container(color: Colors.grey[900]),
                              errorWidget: (context, url, error) => Container(
                                color: Colors.grey[900],
                                child: const Icon(Icons.broken_image, size: 20, color: Colors.grey),
                              ),
                            ),
                          ),
                          if (isVideo)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Icon(
                                  Icons.videocam_rounded,
                                  color: Colors.white,
                                  size: 14,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                  childCount: _uploadedPosts.length,
                ),
              ),
            ),
            if (_isLoadingUploads)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (!_hasMoreUploads && _uploadedPosts.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24.0),
                  child: Center(
                    child: Text(
                      "End of uploads",
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildCreatorProfileHeader(AuthProvider auth) {
    final user = auth.user;
    if (user == null) return const SizedBox.shrink();

    final int totalArts = user.postCount > 0 ? user.postCount : _uploadedPosts.length;
    final int totalUpvotes = _uploadedPosts.fold<int>(0, (sum, p) => sum + p.score);
    final int totalLikes = _uploadedPosts.fold<int>(0, (sum, p) => sum + p.favCount);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Profile Avatar with vibrant gradient ring
              Container(
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Colors.purpleAccent.shade200,
                      Colors.amber.shade700,
                    ],
                    begin: Alignment.bottomLeft,
                    end: Alignment.topRight,
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.all(2.5),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black,
                  ),
                  child: CircleAvatar(
                    radius: 36,
                    backgroundColor: Colors.grey[850],
                    backgroundImage: user.resolvedAvatarUrl != null
                        ? CachedNetworkImageProvider(user.resolvedAvatarUrl!)
                        : null,
                    child: user.resolvedAvatarUrl == null
                        ? Text(
                            user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Creator Stat Columns
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildStatColumn("Arts", totalArts.toString(), Icons.brush_outlined),
                    _buildStatColumn("Upvotes", totalUpvotes.toString(), Icons.arrow_upward_rounded),
                    _buildStatColumn("Likes", totalLikes.toString(), Icons.favorite_border_rounded),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Username
          Text(
            user.name,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          // User Level badge and ID
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 13,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      user.levelString,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                "ID: #${user.id}",
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[500],
                ),
              ),
            ],
          ),
          if (_uploadedPosts.isNotEmpty && totalArts > _uploadedPosts.length) ...[
            const SizedBox(height: 8),
            Text(
              "Showing ${_uploadedPosts.length} of $totalArts uploads (scroll to load more)",
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatColumn(String label, String value, IconData icon) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white70),
            const SizedBox(width: 4),
            Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white70,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildFeedDivider() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.grey[850]!, width: 1),
          bottom: BorderSide(color: Colors.grey[850]!, width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.grid_on_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            "UPLOADS",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyUploadsView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cloud_upload_outlined, size: 48, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            const Text(
              "No uploads found",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "You haven't uploaded any posts to e621 yet, or uploads could not be loaded.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _refreshUploads(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text("Refresh"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGuestUploadsPrompt(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.account_circle_outlined, size: 54, color: Colors.blueAccent),
            ),
            const SizedBox(height: 20),
            const Text(
              "Account Required for Uploads",
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              "Connect your e621 account to view your uploaded arts, like statistics, and upvotes.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LoginPage()),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text("LINK ACCOUNT", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}