import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/collection_filters.dart';
import '../models/collection_model.dart';
import '../providers/auth_provider.dart';
import '../providers/blacklist_provider.dart';
import '../providers/follows_provider.dart';
import '../services/e621_collections_api.dart';
import '../widgets/collection_card.dart';
import '../widgets/collection_search_controls.dart';
import 'settings_page.dart';

class CollectionsPage extends StatefulWidget {
  const CollectionsPage({super.key});

  @override
  State<CollectionsPage> createState() => _CollectionsPageState();
}

class _CollectionsPageState extends State<CollectionsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final follows = Provider.of<FollowsProvider>(context);
    final totalNew = follows.totalNewCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Pools & Sets',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Theme.of(context).colorScheme.primary,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.grey,
          indicatorWeight: 3,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Following'),
                  if (totalNew > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '+$totalNew',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Tab(text: 'Pools'),
            const Tab(text: 'Sets'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _FollowingTab(),
          _PoolsTab(),
          _SetsTab(),
        ],
      ),
    );
  }
}

// ============================================================================
// 1. FOLLOWING TAB
// ============================================================================
class _FollowingTab extends StatefulWidget {
  const _FollowingTab();

  @override
  State<_FollowingTab> createState() => _FollowingTabState();
}

class _FollowingTabState extends State<_FollowingTab> {
  // 'all', 'pools', 'sets', 'my_sets'
  String _selectedFilter = 'all';

  final List<E621Collection> _mySets = [];
  bool _isLoadingMySets = false;
  String? _loadedMySetsUser;

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshFollowsBackground();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Local search over name, description and creator of already loaded collections.
  List<E621Collection> _applySearch(List<E621Collection> source, String query) {
    if (query.isEmpty) return source;
    return source.where((c) => c.matchesMetadataKeyword(query)).toList();
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey[800]!),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 12, right: 2),
              child: Icon(Icons.search, size: 20, color: Colors.grey),
            ),
            Expanded(
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 14),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search followed collections…',
                  hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13.5),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                ),
              ),
            ),
            if (_searchController.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                tooltip: 'Clear',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _searchController.clear();
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoMatches() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.12),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              children: [
                Icon(Icons.search_off, size: 52, color: Colors.grey[600]),
                const SizedBox(height: 16),
                const Text(
                  'No matches',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Nothing here matches "${_searchController.text.trim()}".',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _refreshFollowsBackground() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final follows = Provider.of<FollowsProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders, host: auth.host);
    await follows.refreshFollowedCounts(api);
  }

  Future<void> _fetchMySets(String username) async {
    if (_isLoadingMySets) return;
    setState(() => _isLoadingMySets = true);

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders, host: auth.host);

    try {
      final sets = await api.searchSets(creatorName: username, limit: 50);
      if (mounted) {
        setState(() {
          _mySets.clear();
          _mySets.addAll(sets);
          _loadedMySetsUser = username;
          _isLoadingMySets = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching user sets: $e');
      if (mounted) setState(() => _isLoadingMySets = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final follows = Provider.of<FollowsProvider>(context);

    // If user selected "My Sets" and haven't loaded yet
    if (_selectedFilter == 'my_sets' &&
        auth.isLoggedIn &&
        auth.user != null &&
        _loadedMySetsUser != auth.user!.name &&
        !_isLoadingMySets) {
      _fetchMySets(auth.user!.name);
    }

    final query = _searchController.text.trim();
    final List<FollowedCollection> allItems;
    if (_selectedFilter == 'pools') {
      allItems = follows.followedPools;
    } else if (_selectedFilter == 'sets') {
      allItems = follows.followedSets;
    } else {
      allItems = follows.follows;
    }
    final items = query.isEmpty
        ? allItems
        : allItems.where((i) => i.collection.matchesMetadataKeyword(query)).toList();

    return Column(
      children: [
        _buildSearchField(),

        // Filter Chips row
        Align(
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: CollectionSegments<String>(
              options: [
                ('all', 'All (${follows.follows.length})'),
                ('pools', 'Pools (${follows.followedPools.length})'),
                ('sets', 'Sets (${follows.followedSets.length})'),
                if (auth.isLoggedIn && auth.user != null)
                  ('my_sets', 'My Sets (${_mySets.length})'),
              ],
              selected: _selectedFilter,
              onSelected: (value) => setState(() => _selectedFilter = value),
            ),
          ),
        ),

        // Content
        Expanded(
          child: _selectedFilter == 'my_sets'
              ? _buildMySetsContent()
              : RefreshIndicator(
                  onRefresh: _refreshFollowsBackground,
                  child: items.isEmpty
                      ? (allItems.isNotEmpty ? _buildNoMatches() : _buildEmptyState())
                      : GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(12.0),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12.0,
                            mainAxisSpacing: 12.0,
                            childAspectRatio: 0.82,
                          ),
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];
                            return CollectionCard(
                              collection: item.collection,
                              newCount: item.newCount,
                            );
                          },
                        ),
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.12),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.favorite_border,
                    size: 52,
                    color: Colors.redAccent,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'No collections followed yet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Browse the Pools and Sets tabs and tap the heart icon on any series or set to follow it and receive updates here!',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[400], fontSize: 13.5, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMySetsContent() {
    if (_isLoadingMySets && _mySets.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);

    if (_mySets.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.folder_open, size: 56, color: Colors.grey[600]),
              const SizedBox(height: 16),
              Text(
                'No sets found on ${auth.siteName}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'You have not created any public or private sets on your ${auth.siteName} account.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final query = _searchController.text.trim();
    final shownSets = _applySearch(_mySets, query);

    return RefreshIndicator(
      onRefresh: () => _fetchMySets(auth.user!.name),
      child: shownSets.isEmpty
          ? _buildNoMatches()
          : GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12.0),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12.0,
          mainAxisSpacing: 12.0,
          childAspectRatio: 0.82,
        ),
        itemCount: shownSets.length,
        itemBuilder: (context, index) {
          final setItem = shownSets[index];
          return CollectionCard(collection: setItem);
        },
      ),
    );
  }
}

// ============================================================================
// 2. POOLS TAB
// ============================================================================
class _PoolsTab extends StatefulWidget {
  const _PoolsTab();

  @override
  State<_PoolsTab> createState() => _PoolsTabState();
}

class _PoolsTabState extends State<_PoolsTab> with AutomaticKeepAliveClientMixin {
  final List<E621Collection> _pools = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = false;
  bool _hasMore = true;
  int _page = 1;
  int _generation = 0;
  String? _lastHost;
  Timer? _searchDebounce;

  CollectionFilters _filters = const CollectionFilters();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _lastHost = Provider.of<AuthProvider>(context, listen: false).host;
    _fetchPools(reset: true);

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 300) {
        _fetchPools();
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchTextChanged() {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _fetchPools(reset: true);
    });
  }

  void _setFilters(CollectionFilters next) {
    _searchDebounce?.cancel();
    setState(() => _filters = next.normalized(isPool: true));
    _fetchPools(reset: true);
  }

  /// Pools that survive the blacklist, the local filters and the chosen order.
  List<E621Collection> _visiblePools(
    BlacklistProvider blacklist,
    String query, {
    required bool isSafeMode,
  }) {
    final f = _filters;
    final visible = blacklist
        .filterPools(_pools, isSafeMode: isSafeMode)
        .where((p) => f.passesLocal(p) && f.matchesQuery(p, query))
        .toList();
    return E621CollectionsApi.sortPools(
      visible,
      order: f.order,
      query: query,
      keywordSearch: f.isBroadSearch,
    );
  }

  Future<void> _fetchPools({bool reset = false}) async {
    if (reset) _searchDebounce?.cancel();
    if (_isLoading && !reset) return;
    if (!reset && !_hasMore) return;

    // A reset supersedes any request still in flight.
    final generation = reset ? ++_generation : _generation;
    setState(() {
      _isLoading = true;
      if (reset) {
        _page = 1;
        _hasMore = true;
        _pools.clear();
      }
    });
    if (reset && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders, host: auth.host);
    final activeQuery = _searchController.text.trim();
    final f = _filters;

    try {
      final results = await api.searchPools(
        query: activeQuery,
        category: f.category,
        order: f.order,
        inName: f.inName,
        inDescription: f.inDescription,
        inPosts: f.inPosts,
        creatorName: f.creator,
        isActive: f.isActive,
        page: _page,
        limit: 20,
      );

      if (!mounted || generation != _generation) return;

      setState(() {
        if (reset) _pools.clear();
        final existingIds = _pools.map((p) => p.id).toSet();
        for (final pool in results) {
          if (!existingIds.contains(pool.id)) {
            _pools.add(pool);
            existingIds.add(pool.id);
          }
        }
        final sorted = E621CollectionsApi.sortPools(
          _pools,
          order: f.order,
          query: activeQuery,
          keywordSearch: f.isBroadSearch,
        );
        _pools
          ..clear()
          ..addAll(sorted);

        if (results.length < 20) {
          _hasMore = false;
        } else {
          _page++;
        }
        _isLoading = false;
      });

      // Strict filters can leave the screen almost empty: keep loading a few pages.
      final bl = Provider.of<BlacklistProvider>(context, listen: false);
      final visibleCount =
          _visiblePools(bl, activeQuery, isSafeMode: auth.isSafeMode).length;
      final maxPage =
          (f.minPosts > 0 || (auth.isSafeMode && bl.hideEmptyCollections)) ? 10 : 4;
      if (visibleCount < 6 && _page <= maxPage && results.isNotEmpty && _hasMore) {
        _fetchPools();
      }
    } catch (e) {
      debugPrint('Error fetching pools: $e');
      if (mounted && generation == _generation) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final auth = Provider.of<AuthProvider>(context);
    final blacklist = Provider.of<BlacklistProvider>(context);
    if (_lastHost != null && _lastHost != auth.host) {
      _lastHost = auth.host;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _isLoading = false;
          _fetchPools(reset: true);
        }
      });
    }

    final activeQuery = _searchController.text.trim();
    final showMatches = _filters.inPosts && activeQuery.isNotEmpty;
    final visiblePools =
        _visiblePools(blacklist, activeQuery, isSafeMode: auth.isSafeMode);

    return Column(
      children: [
        CollectionSearchHeader(
          controller: _searchController,
          filters: _filters,
          isPool: true,
          onTextChanged: _onSearchTextChanged,
          onSearch: () => _fetchPools(reset: true),
          onFiltersChanged: _setFilters,
        ),

        // Grid
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _fetchPools(reset: true),
            child: visiblePools.isEmpty && _isLoading
                ? const Center(child: CircularProgressIndicator())
                : visiblePools.isEmpty
                    ? _EmptyResults(
                        noun: 'pools',
                        hiddenCount: _pools.length,
                        canReset: _filters.hasAdvanced,
                        onReset: () => _setFilters(_filters.clearAdvanced()),
                      )
                    : GridView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(12.0),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12.0,
                          mainAxisSpacing: 12.0,
                          childAspectRatio: 0.82,
                        ),
                        itemCount: visiblePools.length + (_isLoading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == visiblePools.length) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          final pool = visiblePools[index];
                          return CollectionCard(
                            key: ValueKey(pool.key),
                            collection: pool,
                            keywordMatchCount:
                                showMatches ? pool.keywordMatchCount(activeQuery) : null,
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }
}

/// Shown when a search has no visible results.
class _EmptyResults extends StatelessWidget {
  final String noun;
  final int hiddenCount;
  final bool canReset;
  final VoidCallback onReset;

  const _EmptyResults({
    required this.noun,
    required this.hiddenCount,
    required this.canReset,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.1),
        Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Icon(Icons.search_off, size: 48, color: Colors.grey[600]),
              const SizedBox(height: 14),
              Text(
                hiddenCount > 0
                    ? 'All $hiddenCount $noun are hidden by your filters or blacklist.'
                    : 'No $noun found.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[400], fontSize: 14),
              ),
              if (canReset) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: const Text('Reset filters'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 3. SETS TAB
// ============================================================================
class _SetsTab extends StatefulWidget {
  const _SetsTab();

  @override
  State<_SetsTab> createState() => _SetsTabState();
}

class _SetsTabState extends State<_SetsTab> with AutomaticKeepAliveClientMixin {
  final List<E621Collection> _sets = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = false;
  bool _hasMore = true;
  int _page = 1;
  int _generation = 0;
  String? _lastHost;
  Timer? _searchDebounce;

  CollectionFilters _filters = const CollectionFilters();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _lastHost = Provider.of<AuthProvider>(context, listen: false).host;
    _fetchSets(reset: true);

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 300) {
        _fetchSets();
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchTextChanged() {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _fetchSets(reset: true);
    });
  }

  void _setFilters(CollectionFilters next) {
    _searchDebounce?.cancel();
    setState(() => _filters = next.normalized(isPool: false));
    _fetchSets(reset: true);
  }

  List<E621Collection> _visibleSets(
    BlacklistProvider blacklist,
    String query, {
    required bool isSafeMode,
  }) {
    final f = _filters;
    final visible = blacklist
        .filterPools(_sets, isSafeMode: isSafeMode)
        .where((s) => f.passesLocal(s) && f.matchesQuery(s, query))
        .toList();
    return E621CollectionsApi.sortPools(
      visible,
      order: f.order,
      query: query,
      keywordSearch: f.isBroadSearch,
    );
  }

  Future<void> _fetchSets({bool reset = false}) async {
    if (reset) _searchDebounce?.cancel();
    if (_isLoading && !reset) return;
    if (!reset && !_hasMore) return;

    final generation = reset ? ++_generation : _generation;
    setState(() {
      _isLoading = true;
      if (reset) {
        _page = 1;
        _hasMore = true;
        _sets.clear();
      }
    });
    if (reset && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders, host: auth.host);
    final activeQuery = _searchController.text.trim();
    final f = _filters;

    try {
      final results = await api.searchSets(
        query: activeQuery,
        creatorName: f.creator,
        order: f.order,
        inName: f.inName,
        inDescription: f.inDescription,
        inPosts: f.inPosts,
        page: _page,
        limit: 20,
      );

      if (!mounted || generation != _generation) return;

      setState(() {
        if (reset) _sets.clear();
        final existingIds = _sets.map((s) => s.id).toSet();
        for (final s in results) {
          if (!existingIds.contains(s.id)) {
            _sets.add(s);
            existingIds.add(s.id);
          }
        }
        final sorted = E621CollectionsApi.sortPools(
          _sets,
          order: f.order,
          query: activeQuery,
          keywordSearch: f.isBroadSearch,
        );
        _sets
          ..clear()
          ..addAll(sorted);
        if (results.length < 20) {
          _hasMore = false;
        } else {
          _page++;
        }
        _isLoading = false;
      });

      // Strict filters can leave the screen almost empty: keep loading a few pages.
      final bl = Provider.of<BlacklistProvider>(context, listen: false);
      final visibleCount =
          _visibleSets(bl, activeQuery, isSafeMode: auth.isSafeMode).length;
      final maxPage =
          (f.minPosts > 0 || (auth.isSafeMode && bl.hideEmptyCollections)) ? 10 : 4;
      if (visibleCount < 6 && _page <= maxPage && results.isNotEmpty && _hasMore) {
        _fetchSets();
      }
    } catch (e) {
      debugPrint('Error fetching sets: $e');
      if (mounted && generation == _generation) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final auth = Provider.of<AuthProvider>(context);
    final blacklist = Provider.of<BlacklistProvider>(context);
    if (_lastHost != null && _lastHost != auth.host) {
      _lastHost = auth.host;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _isLoading = false;
          _fetchSets(reset: true);
        }
      });
    }

    final activeQuery = _searchController.text.trim();
    final showMatches = _filters.inPosts && activeQuery.isNotEmpty;
    final visibleSets =
        _visibleSets(blacklist, activeQuery, isSafeMode: auth.isSafeMode);

    return Column(
      children: [
        CollectionSearchHeader(
          controller: _searchController,
          filters: _filters,
          isPool: false,
          onTextChanged: _onSearchTextChanged,
          onSearch: () => _fetchSets(reset: true),
          onFiltersChanged: _setFilters,
        ),

        // Grid
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _fetchSets(reset: true),
            child: visibleSets.isEmpty && _isLoading
                ? const Center(child: CircularProgressIndicator())
                : visibleSets.isEmpty
                    ? _EmptyResults(
                        noun: 'sets',
                        hiddenCount: _sets.length,
                        canReset: _filters.hasAdvanced,
                        onReset: () => _setFilters(_filters.clearAdvanced()),
                      )
                    : GridView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(12.0),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12.0,
                          mainAxisSpacing: 12.0,
                          childAspectRatio: 0.82,
                        ),
                        itemCount: visibleSets.length + (_isLoading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == visibleSets.length) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          final setItem = visibleSets[index];
                          return CollectionCard(
                            key: ValueKey(setItem.key),
                            collection: setItem,
                            keywordMatchCount:
                                showMatches ? setItem.keywordMatchCount(activeQuery) : null,
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }
}
