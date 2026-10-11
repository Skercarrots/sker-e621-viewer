import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _apiKeyController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final success = await authProvider.login(
      _usernameController.text.trim(),
      _apiKeyController.text.trim(),
    );

    if (success && mounted) {
      Navigator.of(context).pop();
    } else {
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('Linking failed. Please check your credentials.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = Provider.of<AuthProvider>(context).isLoading;

    return Scaffold(
      appBar: AppBar(title: const Text("Link e621 Account")),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Link your account to bypass the e621 global blacklist and access all content. Use your Username and API Key (never your password).",
                style: TextStyle(fontSize: 15),
              ),
              const SizedBox(height: 12),
              const Text(
                "Find your API key on the e621 website: log in to your account, then go to Account -> Manage API Access.",
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 32),
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value!.isEmpty ? 'Enter your username' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _apiKeyController,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  border: OutlineInputBorder(),
                ),
                // Removed obscureText so the user can see what they paste
                validator: (value) => value!.isEmpty ? 'Enter your API key' : null,
              ),
              const SizedBox(height: 32),
              isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      onPressed: _submit,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text("LINK ACCOUNT"),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}