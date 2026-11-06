import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'pages/account_page.dart';
import 'pages/gallery_page.dart';
import 'pages/collections_page.dart';
import 'pages/shared_board_preview_page.dart';
import '../providers/follows_provider.dart';
import '../services/board_share_service.dart';

class MainNavigator extends StatefulWidget {
  const MainNavigator({super.key});

  @override
  State<MainNavigator> createState() => _MainNavigatorState();
}

class _MainNavigatorState extends State<MainNavigator> with WidgetsBindingObserver {
  int _currentIndex = 0;
  String? _lastHandledRoute;

  final List<Widget> _pages = [
    const E621GalleryPage(),
    const CollectionsPage(),
    const AccountPage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initialRoute =
          WidgetsBinding.instance.platformDispatcher.defaultRouteName;
      if (initialRoute.isNotEmpty && initialRoute != '/') {
        _tryHandleIncomingLink(initialRoute);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    final uriStr = routeInformation.uri.toString();
    if (_tryHandleIncomingLink(uriStr)) {
      return true;
    }
    return super.didPushRouteInformation(routeInformation);
  }

  bool _tryHandleIncomingLink(String rawRoute) {
    if (rawRoute.isEmpty || rawRoute == _lastHandledRoute) return false;
    final payload = BoardShareService.tryDecodeAny(rawRoute);
    if (payload == null) return false;

    _lastHandledRoute = rawRoute;
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SharedBoardPreviewPage(payload: payload),
        ),
      );
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // We listen to auth provider just to rebuild the nav bar icons if needed (optional refinement)
    Provider.of<AuthProvider>(context);
    final follows = Provider.of<FollowsProvider>(context);
    final totalNew = follows.totalNewCount;
    final safeIndex = _currentIndex >= _pages.length ? _pages.length - 1 : _currentIndex;

    return Scaffold(
      // IndexedStack keeps the pages alive in the background so scrolling position isn't lost
      body: IndexedStack(
        index: safeIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: safeIndex,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.black,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.grey,
        showSelectedLabels: false,
        showUnselectedLabels: false,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Gallery',
          ),
          BottomNavigationBarItem(
            icon: totalNew > 0
                ? Badge(
                    label: Text('$totalNew'),
                    backgroundColor: Colors.redAccent,
                    child: const Icon(Icons.photo_library_outlined),
                  )
                : const Icon(Icons.photo_library_outlined),
            activeIcon: totalNew > 0
                ? Badge(
                    label: Text('$totalNew'),
                    backgroundColor: Colors.redAccent,
                    child: const Icon(Icons.photo_library),
                  )
                : const Icon(Icons.photo_library),
            label: 'Pools & Sets',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: 'Account',
          ),
        ],
      ),
    );
  }
}
