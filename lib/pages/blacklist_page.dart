import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/blacklist_provider.dart';

class BlacklistPage extends StatefulWidget {
  const BlacklistPage({super.key});

  @override
  State<BlacklistPage> createState() => _BlacklistPageState();
}

class _BlacklistPageState extends State<BlacklistPage> {
  late final TextEditingController _controller;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    final provider = Provider.of<BlacklistProvider>(context, listen: false);
    _controller = TextEditingController(text: provider.rawBlacklist);
    _controller.addListener(() {
      if (!_hasChanges && _controller.text != provider.rawBlacklist) {
        setState(() {
          _hasChanges = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveChanges({bool showSnackbar = true, bool pop = false}) async {
    final provider = Provider.of<BlacklistProvider>(context, listen: false);
    await provider.saveBlacklist(_controller.text);
    setState(() {
      _hasChanges = false;
    });

    if (mounted && showSnackbar) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Blacklist updated successfully.'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    if (mounted && pop) {
      Navigator.of(context).pop();
    }
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Row(
          children: [
            Icon(Icons.help_outline, color: Colors.blueAccent),
            SizedBox(width: 10),
            Text('Blacklist Syntax', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Posts matching any line in your blacklist will be hidden from view.',
                style: TextStyle(fontSize: 13.5, color: Colors.white70),
              ),
              const SizedBox(height: 14),
              _buildHelpRow('Single tag', 'scat', 'Hides any post with the tag "scat"'),
              _buildHelpRow('Multiple tags', 'cub male', 'Hides posts containing BOTH "cub" and "male"'),
              _buildHelpRow('Negation (-)', 'rating:e -solo', 'Hides explicit posts UNLESS they have "solo"'),
              _buildHelpRow('Ratings', 'rating:e / rating:s', 'Filters by explicit (e), questionable (q), or safe (s)'),
              _buildHelpRow('Wildcards (*)', '*vore* / blood*', 'Matches any tag containing the pattern'),
              _buildHelpRow('Comments (#)', '# my notes', 'Lines starting with # are ignored'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it', style: TextStyle(color: Colors.blueAccent)),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpRow(String title, String example, String explanation) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.cyanAccent)),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey[800]!),
            ),
            child: Text(
              example,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.amberAccent),
            ),
          ),
          const SizedBox(height: 2),
          Text(explanation, style: TextStyle(fontSize: 12, color: Colors.grey[400])),
        ],
      ),
    );
  }

  int _countActiveLines() {
    return _controller.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<BlacklistProvider>(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'Blacklist',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.check,
              color: _hasChanges ? Colors.cyanAccent : Colors.white,
            ),
            tooltip: 'Save',
            onPressed: () => _saveChanges(showSnackbar: true, pop: true),
          ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Help',
            onPressed: _showHelpDialog,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: Colors.grey[900],
            onSelected: (value) async {
              if (value == 'reset') {
                setState(() {
                  _controller.text = BlacklistProvider.defaultBlacklist;
                  _hasChanges = true;
                });
                await _saveChanges(showSnackbar: true);
              } else if (value == 'clear') {
                setState(() {
                  _controller.text = '';
                  _hasChanges = true;
                });
                await _saveChanges(showSnackbar: true);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'reset',
                child: Row(
                  children: [
                    Icon(Icons.restart_alt, size: 20, color: Colors.amberAccent),
                    SizedBox(width: 10),
                    Text('Reset to Defaults'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                    SizedBox(width: 10),
                    Text('Clear All'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Subtitle Banner matching Wolf Stash / Sker UI
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.grey[900]?.withValues(alpha: 0.8),
              border: Border(
                bottom: BorderSide(color: Colors.grey[850]!, width: 1),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.filter_alt_off_outlined, size: 18, color: Colors.cyanAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Posts matching a line in the blacklist will be hidden',
                    style: TextStyle(
                      color: Colors.grey[300],
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Multiline Text Editor
          Expanded(
            child: Container(
              color: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 15,
                  height: 1.5,
                  color: Colors.white,
                ),
                decoration: InputDecoration(
                  hintText: 'Enter one tag or tag combination per line...\n\nyoung\nscat\nwatersports\nbestiality',
                  hintStyle: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    color: Colors.grey[600],
                    height: 1.5,
                  ),
                  border: InputBorder.none,
                ),
                onChanged: (_) {
                  setState(() {});
                },
              ),
            ),
          ),

          // Bottom Bar Status
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              border: Border(
                top: BorderSide(color: Colors.grey[850]!, width: 1),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: provider.isEnabled ? Colors.greenAccent : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      provider.isEnabled ? 'Filtering Active' : 'Filtering Disabled',
                      style: TextStyle(
                        fontSize: 12,
                        color: provider.isEnabled ? Colors.greenAccent : Colors.grey,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${_countActiveLines()} ${_countActiveLines() == 1 ? "rule" : "rules"} active',
                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

