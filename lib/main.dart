import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/boards_provider.dart';
import 'providers/follows_provider.dart';
import 'providers/ref_boards_provider.dart';
import 'providers/blacklist_provider.dart';
import 'providers/favorite_tags_provider.dart';
import 'services/local_data_vault.dart';
import 'services/storage_migration_service.dart';
import 'main_navigator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const secureStorage = FlutterSecureStorage();
  final vault = LocalDataVault(keyStorage: secureStorage);
  try {
    await vault.init();
    await StorageMigrationService.migrateIfNeeded(
      vault: vault,
      legacyStorage: secureStorage,
    );
  } catch (e) {
    debugPrint('Vault initialization/migration warning: $e');
  }
  runApp(SkerE621App(vault: vault, secureStorage: secureStorage));
}

class SkerE621App extends StatelessWidget {
  final LocalDataVault? vault;
  final FlutterSecureStorage? secureStorage;

  const SkerE621App({super.key, this.vault, this.secureStorage});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<LocalDataVault?>.value(value: vault),
        ChangeNotifierProvider<BlacklistProvider>(
          create: (context) => BlacklistProvider(
            storage: secureStorage,
            vault: vault,
          )..loadSettings(),
        ),
        ChangeNotifierProvider<FavoriteTagsProvider>(
          create: (context) => FavoriteTagsProvider(
            storage: secureStorage,
            vault: vault,
          )..load(),
        ),
        ChangeNotifierProvider<AuthProvider>(
          create: (context) => AuthProvider(
            storage: secureStorage,
            vault: vault,
          )..tryAutoLogin(),
        ),
        ChangeNotifierProxyProvider<AuthProvider, BoardsProvider>(
          create: (context) => BoardsProvider(
            storage: secureStorage,
            vault: vault,
          ),
          update: (context, auth, boards) {
            final b = boards ??
                BoardsProvider(storage: secureStorage, vault: vault);
            b.updateForUser(auth.user?.name, isGuest: auth.isGuestMode);
            return b;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, FollowsProvider>(
          create: (context) => FollowsProvider(
            storage: secureStorage,
            vault: vault,
          ),
          update: (context, auth, follows) {
            final f = follows ??
                FollowsProvider(storage: secureStorage, vault: vault);
            f.updateForUser(auth.user?.name, isGuest: auth.isGuestMode);
            return f;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, RefBoardsProvider>(
          create: (context) => RefBoardsProvider(
            storage: secureStorage,
            vault: vault,
          ),
          update: (context, auth, refBoards) {
            final rb = refBoards ??
                RefBoardsProvider(storage: secureStorage, vault: vault);
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