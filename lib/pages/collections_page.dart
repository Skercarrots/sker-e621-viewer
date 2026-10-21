import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/collection_model.dart';
import '../providers/auth_provider.dart';
import '../providers/follows_provider.dart';
import '../services/e621_collections_api.dart';
import '../widgets/collection_card.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshFollowsBackground();
    });
  }

  Future<void> _refreshFollowsBackground() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final follows = Provider.of<FollowsProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders);
    await follows.refreshFollowedCounts(api);
  }

  Future<void> _fetchMySets(String username) async {
    if (_isLoadingMySets) return;
    setState(() => _isLoadingMySets = true);

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders);

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

    final List<FollowedCollection> items;
    if (_selectedFilter == 'pools') {
      items = follows.followedPools;
    } else if (_selectedFilter == 'sets') {
      items = follows.followedSets;
    } else {
      items = follows.follows;
    }

    return Column(
      children: [
        // Filter Chips row
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Row(
            children: [
              _buildFilterChip('all', 'All (${follows.follows.length})'),
              const SizedBox(width: 8),
              _buildFilterChip('pools', 'Pools (${follows.followedPools.length})'),
              const SizedBox(width: 8),
              _buildFilterChip('sets', 'Sets (${follows.followedSets.length})'),
              if (auth.isLoggedIn && auth.user != null) ...[
                const SizedBox(width: 8),
                _buildFilterChip('my_sets', 'My Sets (${_mySets.length})'),
              ],
            ],
          ),
        ),

        // Content
        Expanded(
          child: _selectedFilter == 'my_sets'
              ? _buildMySetsContent()
              : RefreshIndicator(
                  onRefresh: _refreshFollowsBackground,
                  child: items.isEmpty
                      ? _buildEmptyState()
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

  Widget _buildFilterChip(String value, String label) {
    final isSelected = _selectedFilter == value;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? Colors.white : Colors.grey[300],
        ),
      ),
      selected: isSelected,
      onSelected: (_) {
        setState(() {
          _selectedFilter = value;
        });
      },
      selectedColor: Theme.of(context).colorScheme.primary,
      backgroundColor: Colors.grey[850],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      side: BorderSide(
        color: isSelected ? Colors.transparent : Colors.grey[800]!,
      ),
      visualDensity: VisualDensity.compact,
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

    if (_mySets.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.folder_open, size: 56, color: Colors.grey[600]),
              const SizedBox(height: 16),
              const Text(
                'No sets found on e621',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'You have not created any public or private sets on your e621 account.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    return RefreshIndicator(
      onRefresh: () => _fetchMySets(auth.user!.name),
      child: GridView.builder(
        padding: const EdgeInsets.all(12.0),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12.0,
          mainAxisSpacing: 12.0,
          childAspectRatio: 0.82,
        ),
        itemCount: _mySets.length,
        itemBuilder: (context, index) {
          final setItem = _mySets[index];
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

  // Filters
  String? _category; // null: all, 'series', 'collection'
  String _order = 'updated_at';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
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
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchPools({bool reset = false}) async {
    if (_isLoading) return;
    if (!reset && !_hasMore) return;

    setState(() => _isLoading = true);
    if (reset) {
      _page = 1;
      _hasMore = true;
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders);

    try {
      final results = await api.searchPools(
        query: _searchController.text.trim(),
        category: _category,
        order: _order,
        page: _page,
        limit: 20,
      );

      if (mounted) {
        setState(() {
          if (reset) _pools.clear();
          _pools.addAll(results);
          if (results.length < 20) {
            _hasMore = false;
          } else {
            _page++;
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching pools: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12.0, 10.0, 12.0, 6.0),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(10),
            ),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search pools by name...',
                hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13.5),
                border: InputBorder.none,
                prefixIcon: const Icon(Icons.search, size: 20, color: Colors.grey),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          _fetchPools(reset: true);
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onSubmitted: (_) => _fetchPools(reset: true),
            ),
          ),
        ),

        // Filters: Category chips + Sort dropdown
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          child: Row(
            children: [
              _buildCategoryChip(null, 'All'),
              const SizedBox(width: 6),
              _buildCategoryChip('series', 'Series'),
              const SizedBox(width: 6),
              _buildCategoryChip('collection', 'Collections'),
              const Spacer(),
              // Sort menu
              PopupMenuButton<String>(
                initialValue: _order,
                icon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sort, size: 18, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      CollectionOrder.pools
                          .firstWhere((o) => o.value == _order)
                          .label,
                      style: TextStyle(fontSize: 11.5, color: Colors.grey[400]),
                    ),
                  ],
                ),
                onSelected: (val) {
                  setState(() => _order = val);
                  _fetchPools(reset: true);
                },
                itemBuilder: (context) => CollectionOrder.pools
                    .map((o) => PopupMenuItem(
                          value: o.value,
                          child: Text(o.label, style: const TextStyle(fontSize: 13)),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),

        // Grid
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _fetchPools(reset: true),
            child: _pools.isEmpty && _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _pools.isEmpty
                    ? const Center(child: Text('No pools found.'))
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
                        itemCount: _pools.length + (_isLoading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _pools.length) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          return CollectionCard(collection: _pools[index]);
                        },
                      ),
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryChip(String? category, String label) {
    final isSelected = _category == category;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? Colors.white : Colors.grey[400],
        ),
      ),
      selected: isSelected,
      onSelected: (_) {
        setState(() => _category = category);
        _fetchPools(reset: true);
      },
      selectedColor: Theme.of(context).colorScheme.primary,
      backgroundColor: Colors.grey[850],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      side: BorderSide(color: isSelected ? Colors.transparent : Colors.grey[800]!),
      visualDensity: VisualDensity.compact,
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
  String _order = 'updated_at';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
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
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchSets({bool reset = false}) async {
    if (_isLoading) return;
    if (!reset && !_hasMore) return;

    setState(() => _isLoading = true);
    if (reset) {
      _page = 1;
      _hasMore = true;
    }

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final api = E621CollectionsApi(auth.authHeaders);

    try {
      final results = await api.searchSets(
        query: _searchController.text.trim(),
        order: _order,
        page: _page,
        limit: 20,
      );

      if (mounted) {
        setState(() {
          if (reset) _sets.clear();
          _sets.addAll(results);
          if (results.length < 20) {
            _hasMore = false;
          } else {
            _page++;
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching sets: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12.0, 10.0, 12.0, 6.0),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(10),
            ),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search sets by name...',
                hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13.5),
                border: InputBorder.none,
                prefixIcon: const Icon(Icons.search, size: 20, color: Colors.grey),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          _fetchSets(reset: true);
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onSubmitted: (_) => _fetchSets(reset: true),
            ),
          ),
        ),

        // Sort menu header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PopupMenuButton<String>(
                initialValue: _order,
                icon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sort, size: 18, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      CollectionOrder.sets
                          .firstWhere((o) => o.value == _order)
                          .label,
                      style: TextStyle(fontSize: 11.5, color: Colors.grey[400]),
                    ),
                  ],
                ),
                onSelected: (val) {
                  setState(() => _order = val);
                  _fetchSets(reset: true);
                },
                itemBuilder: (context) => CollectionOrder.sets
                    .map((o) => PopupMenuItem(
                          value: o.value,
                          child: Text(o.label, style: const TextStyle(fontSize: 13)),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),

        // Grid
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _fetchSets(reset: true),
            child: _sets.isEmpty && _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _sets.isEmpty
                    ? const Center(child: Text('No sets found.'))
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
                        itemCount: _sets.length + (_isLoading ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _sets.length) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          return CollectionCard(collection: _sets[index]);
                        },
                      ),
          ),
        ),
      ],
    );
  }
}

