import 'package:flutter/material.dart';
import 'package:provider/provider.dart'; // Import Provider
import 'providers/auth_provider.dart'; // Import the AuthProvider
import 'providers/boards_provider.dart'; // Import the BoardsProvider
import 'providers/follows_provider.dart'; // Import the FollowsProvider
import 'main_navigator.dart'; // We will create this shortly

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SkerE621App());
}

class SkerE621App extends StatelessWidget {
  const SkerE621App({super.key});

  @override
  Widget build(BuildContext context) {
    // Provide AuthProvider, BoardsProvider and FollowsProvider
    return MultiProvider(
      providers: [
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
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Sker e621 Viewer',
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          // Add a color scheme to help with Instagram look
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
        // We point home to a new MainNavigator instead of directly to the gallery
        home: const MainNavigator(),
      ),
    );
  }
}