import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'pages/account_page.dart';
import 'pages/gallery_page.dart';
import 'pages/collections_page.dart';
import 'pages/refs_studio_page.dart';
import '../providers/follows_provider.dart';

class MainNavigator extends StatefulWidget {
  const MainNavigator({super.key});

  @override
  State<MainNavigator> createState() => _MainNavigatorState();
}

class _MainNavigatorState extends State<MainNavigator> {
  int _currentIndex = 0; 

  final List<Widget> _pages = [
    const E621GalleryPage(),
    const CollectionsPage(),
    const RefsStudioPage(),
    const AccountPage(),
  ];

  @override
  Widget build(BuildContext context) {
    // We listen to auth provider just to rebuild the nav bar icons if needed (optional refinement)
    Provider.of<AuthProvider>(context);
    final follows = Provider.of<FollowsProvider>(context);
    final totalNew = follows.totalNewCount;

    return Scaffold(
      // IndexedStack keeps the pages alive in the background so scrolling position isn't lost
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
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
            icon: Icon(Icons.draw_outlined),
            activeIcon: Icon(Icons.draw, color: Colors.cyanAccent),
            label: 'Refs & Studio',
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