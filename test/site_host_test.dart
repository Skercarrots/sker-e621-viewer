import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:skerdev_e621/pages/settings_page.dart';
import 'package:skerdev_e621/providers/auth_provider.dart';
import 'package:skerdev_e621/providers/blacklist_provider.dart';
import 'widget_test.dart';

void main() {
  group('Site Host Configuration & 18+ Verification Tests', () {
    test('defaults to e926.net (safe mode) out of the box', () {
      final storage = FakeSecureStorage();
      final auth = AuthProvider(storage: storage);

      expect(auth.host, 'e926.net');
      expect(auth.isSafeMode, isTrue);
      expect(auth.siteName, 'e926');
      expect(auth.isOver18Verified, isFalse);
    });

    test('normalizes e621 and e926 host inputs accurately', () {
      expect(AuthProvider.normalizeHost('e621'), 'e621.net');
      expect(AuthProvider.normalizeHost('e621.net'), 'e621.net');
      expect(AuthProvider.normalizeHost('https://e621.net/posts'), 'e621.net');
      expect(AuthProvider.normalizeHost('  WWW.E621.NET '), 'e621.net');

      expect(AuthProvider.normalizeHost('e926'), 'e926.net');
      expect(AuthProvider.normalizeHost('e926.net'), 'e926.net');
      expect(AuthProvider.normalizeHost('https://e926.net/'), 'e926.net');

      // Unknown or empty values fall back to safe default e926.net
      expect(AuthProvider.normalizeHost(''), 'e926.net');
      expect(AuthProvider.normalizeHost('invalid.com'), 'e926.net');
    });

    test('blocks host change if over 18 is not confirmed, and persists when confirmed', () async {
      final storage = FakeSecureStorage();
      final auth = AuthProvider(storage: storage);

      // Rejects when over18Confirmed is false
      final rejected = await auth.setSiteHost('e621', over18Confirmed: false);
      expect(rejected, isFalse);
      expect(auth.host, 'e926.net');
      expect(auth.isSafeMode, isTrue);

      // Accepts when over18Confirmed is true
      final accepted = await auth.setSiteHost('e621', over18Confirmed: true);
      expect(accepted, isTrue);
      expect(auth.host, 'e621.net');
      expect(auth.isSafeMode, isFalse);
      expect(auth.siteName, 'e621');
      expect(auth.isOver18Verified, isTrue);

      // Persists across sessions
      final authNextSession = AuthProvider(storage: storage);
      await authNextSession.tryAutoLogin(refreshInBackground: false);
      expect(authNextSession.host, 'e621.net');
      expect(authNextSession.isSafeMode, isFalse);
      expect(authNextSession.isOver18Verified, isTrue);
    });

    testWidgets('SettingsPage requires 18+ confirmation before changing site/host', (WidgetTester tester) async {
      final storage = FakeSecureStorage();
      final authProvider = AuthProvider(storage: storage);
      final blacklistProvider = BlacklistProvider(storage: storage);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
            ChangeNotifierProvider<BlacklistProvider>.value(value: blacklistProvider),
          ],
          child: const MaterialApp(
            home: SettingsPage(),
          ),
        ),
      );

      // Initially shows e926.net under Change site/host
      expect(find.text('Change site/host'), findsOneWidget);
      expect(find.text('e926.net'), findsOneWidget);
      expect(find.text('Link e926 Account'), findsOneWidget);

      // Tap Change site/host -> should show Age Confirmation dialog first
      await tester.tap(find.text('Change site/host'));
      await tester.pumpAndSettle();

      expect(find.text('Age Confirmation'), findsOneWidget);
      expect(find.text('I am over 18'), findsOneWidget);

      // If user taps Cancel on Age Confirmation, host input dialog does not open
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Age Confirmation'), findsNothing);
      expect(authProvider.host, 'e926.net');

      // Tap Change site/host again and agree to I am over 18
      await tester.tap(find.text('Change site/host'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I am over 18'));
      await tester.pumpAndSettle();

      // Now the Change site/host input dialog is visible
      expect(find.byType(TextField), findsOneWidget);

      // User types "e621" (or "e621.net") and taps OK
      await tester.enterText(find.byType(TextField), 'e621');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Host is updated to e621.net
      expect(authProvider.host, 'e621.net');
      expect(find.text('e621.net'), findsOneWidget);
      expect(find.text('Link e621 Account'), findsOneWidget);
    });
  });
}

