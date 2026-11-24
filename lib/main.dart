import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/boards_provider.dart';
import 'providers/follows_provider.dart';
import 'providers/ref_boards_provider.dart';
import 'providers/blacklist_provider.dart';
import 'main_navigator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SkerE621App());
}

class SkerE621App extends StatelessWidget {
  const SkerE621App({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<BlacklistProvider>(
          create: (context) => BlacklistProvider()..loadSettings(),
        ),
        ChangeNotifierProvider<AuthProvider>(
          create: (context) => AuthProvider()..tryAutoLogin(),
        ),
        ChangeNotifierProxyProvider<AuthProvider, BoardsProvider>(
          create: (context) => BoardsProvider(),
          update: (context, auth, boards) {
            final b = boards ?? BoardsProvider();
            b.updateForUser(auth.user?.name, isGuest: auth.isGuestMode);
            return b;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, FollowsProvider>(
          create: (context) => FollowsProvider(),
          update: (context, auth, follows) {
            final f = follows ?? FollowsProvider();
            f.updateForUser(auth.user?.name, isGuest: auth.isGuestMode);
            return f;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, RefBoardsProvider>(
          create: (context) => RefBoardsProvider(),
          update: (context, auth, refBoards) {
            final rb = refBoards ?? RefBoardsProvider();
            rb.updateForUser(auth.user?.name, isGuest: auth.isGuestMode);
            return rb;
          },
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Sker e621 Viewer',
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          colorScheme: ColorScheme.dark(
             primary: Colors.blueAccent,
             secondary: Colors.blueGrey[700]!,
             surface: Colors.black,
          ),
          scaffoldBackgroundColor: Colors.black,
          appBarTheme: const AppBarTheme(backgroundColor: Colors.black, elevation: 0),
          bottomNavigationBarTheme: const BottomNavigationBarThemeData(
            backgroundColor: Colors.black,
            selectedItemColor: Colors.white,
            unselectedItemColor: Colors.grey,
          )
        ),
        home: const MainNavigator(),
      ),
    );
  }
}