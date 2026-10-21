import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/blacklist_provider.dart';
import 'blacklist_page.dart';
import 'login_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  // Method to display confirmation dialog
  Future<void> _showUnlinkDialog(BuildContext context, AuthProvider authProvider) async {
    final bool isGuest = authProvider.isGuestMode;

    return showDialog<void>(
      context: context,
      barrierDismissible: false, // User must tap a button
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(isGuest ? 'Exit Guest Mode?' : 'Unlink Account?'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                  isGuest
                      ? 'This will return you to the main screen. You can enter Guest Mode or link an account again later.'
                      : 'Are you sure you want to unlink your e621 account? You will lose access to your remote favorites and the global blacklist will be re-enabled.',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: Text(isGuest ? 'Exit' : 'Unlink'),
              onPressed: () {
                authProvider.logout();
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final blacklistProvider = Provider.of<BlacklistProvider>(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          "Settings",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        children: [
          // --- BLACKLIST SECTION (Wolf Stash style with Sker dark UI) ---
          _buildSectionHeader(context, "BLACKLIST & FILTERING"),

          ListTile(
            leading: const Icon(Icons.block, color: Colors.white),
            title: const Text(
              "Manage blacklist",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${blacklistProvider.ruleCount} active ${blacklistProvider.ruleCount == 1 ? "rule" : "rules"}',
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BlacklistPage()),
              );
            },
          ),

          SwitchListTile(
            secondary: const Icon(Icons.settings_outlined, color: Colors.white),
            title: const Text(
              "Blacklist enabled",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              "Disable to show all posts, including those that match the blacklist",
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            value: blacklistProvider.isEnabled,
            activeThumbColor: Theme.of(context).colorScheme.primary,
            onChanged: (val) {
              blacklistProvider.setEnabled(val);
            },
          ),

          SwitchListTile(
            secondary: const Icon(Icons.pool, color: Colors.white),
            title: const Text(
              "Blacklist pool posts",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              "Enable to apply your blacklist to posts in a pool",
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            value: blacklistProvider.blacklistPoolPosts,
            activeThumbColor: Theme.of(context).colorScheme.primary,
            onChanged: (val) {
              blacklistProvider.setBlacklistPoolPosts(val);
            },
          ),

          const Divider(color: Colors.white12, height: 28),

          // --- ACCOUNT SECTION ---
          _buildSectionHeader(context, "ACCOUNT"),

          ListTile(
            leading: Icon(
              (authProvider.isLoggedIn || authProvider.isGuestMode)
                  ? Icons.link_off
                  : Icons.link,
              color: (authProvider.isLoggedIn || authProvider.isGuestMode)
                  ? Colors.redAccent
                  : Colors.blueAccent,
            ),
            title: Text(
              authProvider.isLoggedIn
                  ? "Unlink Account"
                  : authProvider.isGuestMode
                      ? "Exit Guest Mode"
                      : "Link e621 Account",
              style: TextStyle(
                color: (authProvider.isLoggedIn || authProvider.isGuestMode)
                    ? Colors.redAccent
                    : Colors.blueAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              authProvider.isLoggedIn
                  ? "Logged in as ${authProvider.user?.name ?? 'User'}"
                  : authProvider.isGuestMode
                      ? "Browsing as Guest"
                      : "Connect with username and API key",
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            onTap: () {
              if (authProvider.isLoggedIn || authProvider.isGuestMode) {
                _showUnlinkDialog(context, authProvider);
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const LoginPage()),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}