import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/blacklist_provider.dart';
import '../providers/ref_boards_provider.dart';
import '../services/backup_service.dart';
import '../widgets/data_backup_sheets.dart';
import 'blacklist_page.dart';
import 'login_page.dart';

class SettingsPage extends StatelessWidget {
  final BackupFileIo? backupFileIo;

  const SettingsPage({super.key, this.backupFileIo});

  Future<bool> _showOver18Dialog(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amberAccent),
              SizedBox(width: 10),
              Expanded(child: Text('Age Confirmation')),
            ],
          ),
          content: const Text(
            'You must be at least 18 years old to change the site/host configuration.\n\n'
            'Do you confirm and agree that you are over 18 years of age?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('I am over 18'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _showChangeHostFlow(BuildContext context, AuthProvider authProvider) async {
    if (authProvider.host == AuthProvider.defaultHost) {
      final confirmedOver18 = await _showOver18Dialog(context);
      if (!confirmedOver18 || !context.mounted) return;
    }

    final newHostInput = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => _HostInputDialog(initialHost: authProvider.host),
    );

    if (newHostInput != null && context.mounted) {
      await authProvider.setSiteHost(newHostInput, over18Confirmed: true);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('Site/host set to ${authProvider.host}'),
              duration: const Duration(seconds: 2),
            ),
          );
      }
    }
  }

  Future<void> _showUnlinkDialog(BuildContext context, AuthProvider authProvider) async {
    final bool isGuest = authProvider.isGuestMode;

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(isGuest ? 'Exit Guest Mode?' : 'Unlink Account?'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                  isGuest
                      ? 'This will return you to the main screen. You can enter Guest Mode or link an account again later.'
                      : 'Are you sure you want to unlink your ${authProvider.siteName} account? You will lose access to your remote favorites and the global blacklist will be re-enabled.',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: Text(isGuest ? 'Exit' : 'Unlink'),
              onPressed: () async {
                await authProvider.logout();
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
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

  RefBoardsProvider? _maybeRefBoards(BuildContext context) {
    try {
      return Provider.of<RefBoardsProvider>(context);
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final blacklistProvider = Provider.of<BlacklistProvider>(context);
    final refBoardsProvider = _maybeRefBoards(context);
    final bool isArtistMode = refBoardsProvider?.artistModeEnabled ?? false;
    final bool hasSavedCanvases = refBoardsProvider?.refBoards.isNotEmpty ?? false;

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
          _buildSectionHeader(context, "GENERAL"),

          ListTile(
            leading: const Icon(Icons.warning_amber_rounded, color: Colors.white),
            title: const Text(
              "Change site/host",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              authProvider.host,
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            onTap: () => _showChangeHostFlow(context, authProvider),
          ),

          if (refBoardsProvider != null)
            SwitchListTile(
              secondary: Icon(
                Icons.brush_outlined,
                color: isArtistMode ? Colors.cyanAccent : Colors.white,
              ),
              title: const Text(
                "Artist Mode",
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                "Show Reference Canvas tools for collecting, arranging, and studying art references",
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
              value: isArtistMode,
              activeThumbColor: Colors.cyanAccent,
              onChanged: (val) async {
                await refBoardsProvider.setArtistModeEnabled(val);
                if (!context.mounted) return;
                final messenger = ScaffoldMessenger.of(context);
                messenger.clearSnackBars();
                if (val) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Artist Mode enabled — Ref Canvas is now available in Account and Post pages.',
                      ),
                      duration: Duration(seconds: 3),
                    ),
                  );
                } else if (refBoardsProvider.refBoards.isNotEmpty) {
                  final count = refBoardsProvider.refBoards.length;
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Artist Mode disabled. Your $count ref ${count == 1 ? 'canvas is' : 'canvases are'} safely kept.',
                      ),
                      duration: const Duration(seconds: 4),
                      action: SnackBarAction(
                        label: 'UNDO',
                        onPressed: () {
                          refBoardsProvider.setArtistModeEnabled(true);
                        },
                      ),
                    ),
                  );
                }
              },
            ),

          const Divider(color: Colors.white12, height: 28),

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

          SwitchListTile(
            secondary: const Icon(Icons.collections_bookmark_outlined, color: Colors.white),
            title: const Text(
              "Hide pools with blacklisted posts",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              "Enable to hide pools that contain blacklisted posts from results",
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            value: blacklistProvider.hideBlacklistedPools,
            activeThumbColor: Theme.of(context).colorScheme.primary,
            onChanged: (val) {
              blacklistProvider.setHideBlacklistedPools(val);
            },
          ),

          SwitchListTile(
            secondary: const Icon(Icons.hide_image_outlined, color: Colors.white),
            title: const Text(
              "Hide empty pools and sets",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              "Disable to show pools and sets even when they have 0 viewable images",
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            value: blacklistProvider.hideEmptyCollections,
            activeThumbColor: Theme.of(context).colorScheme.primary,
            onChanged: (val) {
              blacklistProvider.setHideEmptyCollections(val);
            },
          ),

          const Divider(color: Colors.white12, height: 28),

          _buildSectionHeader(context, "DATA & BACKUP"),

          ListTile(
            leading: const Icon(Icons.backup_outlined, color: Colors.white),
            title: const Text(
              "Export data",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              (isArtistMode || hasSavedCanvases)
                  ? "Save boards, ref canvases, tags, follows, and settings"
                  : "Save boards, tags, follows, and settings",
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => showExportDataSheet(context, fileIo: backupFileIo),
          ),

          ListTile(
            leading: const Icon(Icons.restore_outlined, color: Colors.white),
            title: const Text(
              "Import data",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              "Restore or merge from a .skerbackup file",
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => showImportDataFlow(context, fileIo: backupFileIo),
          ),

          ListTile(
            leading: const Icon(Icons.history_outlined, color: Colors.white),
            title: const Text(
              "Recovery snapshots",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              "Restore automatic pre-update or pre-import backups",
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => showRecoverySnapshotsSheet(context),
          ),

          const Divider(color: Colors.white12, height: 28),

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
                      : "Link ${authProvider.siteName} Account",
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

class _HostInputDialog extends StatefulWidget {
  final String initialHost;

  const _HostInputDialog({required this.initialHost});

  @override
  State<_HostInputDialog> createState() => _HostInputDialogState();
}

class _HostInputDialogState extends State<_HostInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialHost);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.grey[900],
      title: const Text('Change site/host'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: Colors.white54),
          ),
        ),
        onSubmitted: (val) => Navigator.of(context).pop(val),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
