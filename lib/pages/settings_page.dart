import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
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
          title: Text(isGuest ? 'Exit Guest Mode?' : 'Unlink Account?'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(isGuest 
                  ? 'This will return you to the main screen. You can enter Guest Mode or link an account again later.'
                  : 'Are you sure you want to unlink your e621 account? You will lose access to your remote favorites and the global blacklist will be re-enabled.'),
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

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Settings"),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: Icon((authProvider.isLoggedIn || authProvider.isGuestMode) 
                ? Icons.link_off 
                : Icons.link),
            title: Text(
              authProvider.isLoggedIn 
                  ? "Unlink Account" 
                  : authProvider.isGuestMode ? "Exit Guest Mode" : "Link e621 Account",
              style: TextStyle(
                color: (authProvider.isLoggedIn || authProvider.isGuestMode) 
                    ? Colors.redAccent 
                    : Colors.blueAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
            onTap: () {
              if (authProvider.isLoggedIn || authProvider.isGuestMode) {
                // Show confirmation dialog instead of unlinking directly
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